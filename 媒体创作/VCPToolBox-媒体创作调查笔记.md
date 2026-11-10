# VCPToolBox 媒体创作调查笔记

> 调查对象：`https://github.com/lioensky/VCPToolBox`（Node 服务端 + 插件架构）
>
> 调查更新日期：2026-11-04
>
> 代码快照：`018cd7fae1bbcf6a993bc45dcdd0914f909ca3bf`（分支：`main`）
>
> 调查方式：只读源码梳理 + 尽力而为运行验证。通读 `Plugin/MediaRenderer/`（manifest、MediaRenderer.js 全文 2194 行、AudioSynthesisWorker.js、README、config.env.example），node 解析 15 个媒体插件 manifest，核对 `Plugin.js` hybridservice/asynchronous 分发、`server.js:1471` 回调端点、`modules/messageProcessor.js:827-867` 回注、`WebSocketServer.js:95-144` 分布式回调；运行验证含 `node --check`、音频 Worker 独立实测（成功与错误路径）、FFmpeg 按插件参数实测编码 GIF/MP4
>
> 调查范围：媒体创作类目视角（M2 可编程渲染、M4 插件编排、异步回注、资源白名单治理）；通用工具协议、Agent 审批、分布式任务等机制细节归并 Agent 工具类目；外部模型真实生成与托管浏览器渲染未运行（无 node_modules、无外部 key）
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPToolBox 的媒体创作能力是**服务端媒体供给/编排层**：项目本身没有最终用户媒体工作台或聊天 UI，Agent（模型）是主要创作者，通过 VCP 统一工具协议（`<<<[TOOL_REQUEST]>>>` + 中文「始」「末」边界符）调用媒体插件族。媒体主链由四类执行域构成：

1. **外部图像/视频/配音模型 API 插件**：启用的同步图像插件 9 个、异步视频插件 2 个、异步配音插件 1 个，另有 2 个以 `.block` 后缀停用；插件把结果 URL 交回模型，由模型在回复中嵌入图片、视频或音频标签展示；
2. **MediaRenderer 可编程渲染**（hybridservice/direct 分发，需管理员权限）：服务端把 HTML 或 SVG 交托管 Chrome 截图得到静态图，或按确定性时间轴逐帧采集后交 FFmpeg 编码成 GIF/MP4/WebM；AI 合成的代码在 Node 子进程里执行，产出 PCM16 WAV；
3. **ImageFileServer 图床/文件服务**：以 `/pw=[key]/images|files/...` 路径静态托管全部产物，是媒体结果持久化的真源；
4. **异步回注链**：异步视频与配音插件（Wan2.1、MimoDubbing）在后台轮询到终态后回调 `/plugin-callback/:pluginName/:taskId`，结果写成 `VCPAsyncResults/<plugin>-<taskId>.json`，后续请求由占位符读文件注入上下文；分布式节点经 `plugin_callback_forward` 消息回送，落盘走同一条链。

**核心边界**：媒体事实对象是"插件调用 + 产物文件 + 可选异步 job 文件"，**不存在**任务/历史/资产记录、去重索引、版本或用户可浏览的创作历史 UI；持续性与复用依赖文件服务 URL 的再次引用。资源白名单（单资源 50MB/总 100MB/每步 24 资源/源码 2MB/帧数上限/30M 采样数）、脚本白名单（内置 Anime.js/Three.js/Pixi.js）、页面运行时网络全阻断、云元数据地址常禁、音频 requireAdmin 6 位验证码构成治理契约。

MediaRenderer 现增加 Windows 鼠标主题生成：模型提交一份包含角色 SVG 的 HTML，服务端要求 15 个核心角色各声明一次（`pin`、`person` 可回退至箭头），在 16--256 像素的指定档位逐个截图；静态角色编码为多尺寸 CUR，带确定性绝对时间渲染函数的角色编码为 ANI。结果写为含光标、预览、原始 HTML、安装/卸载脚本和 `theme.json` 的 ZIP，并另托管总览 PNG。它扩大了可编程媒体的交付物类型，但 ZIP 内的源文件与元数据仍只是可下载文件，不形成可查询、可版本化的媒体工程对象（`Plugin/MediaRenderer/MediaRenderer.js:1683-2194`、`CursorThemePackager.js:11-697`）。

**证据分层**：全链为源码事实；`node --check` 通过、音频 Worker 成功/失败两路径实测、FFmpeg GIF/MP4 编码实测、16 份 manifest 解析通过（运行验证）；真实渲染输出、外部模型生成、回调端到端注入、托管浏览器进程行为未验证。

## 系统边界与完整主链

**与独特功能笔记的交接**：独特功能能力十（多媒体生成与媒体插件族）、能力五（异步任务回注）、能力十七（UserAuth 认证码）已提供完整源码调查（见 [`../独特功能/VCPToolBox-独特功能调查笔记.md`](../独特功能/VCPToolBox-独特功能调查笔记.md) 能力卡）；本页只做媒体创作类目视角的归位与补证，不重复抄写。

**本仓库范围**：媒体主链全部位于本仓库（VCPToolBox）内；任务提示中的 `VCPDistributedServer/` 目录实际属于兄弟仓库 VCPChat，不在本快照内。VCPToolBox 侧的分布式回注链由 `server.js:1471` 的 HTTP 回调端点与 `WebSocketServer.js:95-144` 的 `plugin_callback_forward` 分发组成。

**完整主链（以 MediaRenderer RenderImage 为代表）**：

```text
Agent 输出 <<<[TOOL_REQUEST]>>>（含 html/svg、width/height、资源 URL）
  → ToolExecutor/PluginManager.processToolCall（Plugin.js:1164）
  → hybridservice/direct 分发，注入 decryptedAuthCode（Plugin.js:1303-1334）
  → normalizeRequest 参数清洁（MediaRenderer.js:306-389）
  → Node 侧资源预取：逐跳校验 DNS/地址/大小 → 改写 Data URI（resolveAssets:640、
    resolveDirectSourceAssets:727、assertRemoteAssetUrlAllowed:507）
  → browserRuntimeManager.ensureManagedBrowser() + connectToManagedBrowser（:1551-1569）
  → 独立 browser context + 页面（installNetworkPolicy:933 阻断运行时网络）
  → 截图（capturePng:1238）/ 逐帧+FFmpeg（encodeAnimation:1252）
  → saveArtifact:1320 写 image/|file/media-renderer/（:1335-1342）
  → 返回 { text: 渲染成功 + 可访问URL + <img>/<video> 展示提示, details: 元数据 }
  → 模型在回复中引用 URL 展示；URL 可作后续工具参数复用
```

**完整主链（GenerateAudio）**：模型以 `command=generateaudio` 直接调用时，MediaRenderer 先比对 6 位验证码，再清洁请求参数，然后用 `node --max-old-space-size=512 AudioSynthesisWorker.js` 起一个独立子进程，经 stdin 传入 JSON，由 AI 合成代码写出 PCM16 WAV；主进程重新校验 WAV 头、PCM 数据与时长，通过后交 saveArtifact 托管进文件服务。验证码比对、参数清洁、子进程执行与产物校验见 `MediaRenderer.js:1664-1666,391-463,1147-1177`。

**完整主链（GenerateCursorTheme）**：模型提交 HTML、主题名和可选尺寸 → 复用资源预取、网络阻断与托管 Chrome → 页面加载后验证角色名、顶层 SVG、viewBox、热点、动画帧数及全主题帧数 → 每个角色按绝对 `timeMs` 截图 32/48/64 等多尺寸 PNG → 静态帧编码 CUR、动画帧编码 ANI → 生成带首帧及热点十字的总览 PNG 和安装包 ZIP → `saveArtifact` 分别托管 ZIP 与预览 URL 并回注模型。主题默认包含 15 个核心角色，两个扩展角色缺失时在安装配置中回退到箭头；真实 Windows 安装及光标视觉效果未运行验证（`MediaRenderer.js:1667-2058`、`CursorThemePackager.js:11-685`）。

**完整主链（Wan2.1 视频异步回注）**：模型提交生成任务后，插件立即返回 requestId，同时在自己进程内起后台线程轮询外部 API，直到成功、失败或超时，再把终态 POST 到回调地址；服务端回调端点把结果写成 `VCPAsyncResults/Wan2.1VideoGen-<id>.json`，manifest 打开 webSocketPush 时另行广播进度。模型需要在回复中保留异步结果占位符，后续请求由消息处理器读该文件替换成结果文本，文件尚未生成时替换为"结果待更新..."。轮询与回调地址注入、回调落盘、占位符替换见 `video_handler.py:214-302,440,465`、`Plugin.js:1553-1562`、`server.js:1471,1500-1512`、`modules/messageProcessor.js:830-868`。

## 1. 创作入口、触发者与事实对象

- **入口**：项目没有面向媒体的 UI 入口。媒体能力靠插件 manifest 里的 `invocationCommands` 描述注入模型上下文，Agent 读到描述后按约定输出工具块来触发；管理面板只负责插件的启用与禁用，不承载创作动作。
- **触发者**：模型是主要创作者，用户把需求写进对话提示词，由模型转成工具调用，界面上没有直接点按即可生成的按钮。任务提示所设想的"独立聊天 UI"在本快照中不存在，VCPToolBox 本身是服务端中间层。
- **事实对象**：媒体侧的事实对象只有下面几类，均无"记录"语义。
  1. 插件调用：调用结束后没有持久化的记录对象，`toolCallRecordStore` 保存的工具调用记录归 Agent 工具类目。
  2. 产物文件：MediaRenderer 写入 `image/media-renderer/`（PNG/JPG/WebP/GIF）与 `file/media-renderer/`（MP4/WebM/WAV），文件名为 `<stem>-<Date.now()>-<3字节随机>.ext`，图像插件写各自子目录（如 `image/fluxgen/`）。命名规则见 `MediaRenderer.js:1323`，FluxGen 的目录约定见其 manifest 描述。
  3. 异步 job 文件：`VCPAsyncResults/<pluginName>-<taskId>.json`，没有过期清理（独特功能笔记能力五已记录）。
  4. 光标主题 ZIP：打包 CUR/ANI、原始 HTML、`theme.json` 与安装文件，交付形态仍是文件服务里的一次性 URL，没有主题记录或版本链。

## 2. 参数、素材与模型/渲染执行

**参数进入请求**：VCP 工具块语法（中文「始」「末」边界符、英文逗号分隔参数），由 PluginManager 解析后按插件分发（`Plugin.js:1164` processToolCall）。manifest 描述即参数契约（`Plugin/MediaRenderer/plugin-manifest.json` 三命令含完整参数表与示例）。

**MediaRenderer 参数清洁（RenderImage/RenderAnimation）**：渲染命令进入执行前，normalizeRequest 会统一补齐并校验参数，具体实现见 `MediaRenderer.js:306-389,163-168,1512-1549`。
- 宽高必填，取值 64-4096 像素，总像素不超过 4096²；
- 输出格式支持 png/jpg/webp/gif/mp4/webm；透明背景配 JPG 时自动改用 PNG，配 MP4 则拒绝；
- 源码在 html 与 svg 之间二选一，大小不超过 2MB；
- 动画帧数由 `ceil(durationMs×fps/1000)` 算出，不得超过 MaxAnimationFrames（默认 600，上限 3600）；
- durationMs 取 100-60000，fps 取 1-60，waitMs 不超过 10000，timeoutMs 取 1000-120000；
- allowJavaScript 默认关闭，动画、内置库与 CDN 标签会自动开启；JS 是否运行由这个静态开关决定，执行时不再另行判断；
- 批量调用用数字后缀参数（command1、html1 等）串行执行，最多 16 步，公共参数作各步的默认值。

**素材进入请求（白名单预取）**：MediaRenderer 在渲染前先把页面所需的外部素材取回并改写，托管浏览器只接触内联数据。

- 源码中直接写出的地址：图片、视频、音频、字幕、链接与输入类元素上的可寻址属性，加上 srcset 与 CSS `url()`，统一由 collectDirectSourceUrls 收集（`MediaRenderer.js:698-725`），完整元素与属性清单见本节末尾代码块；
- 兼容参数：assets JSON 与 sourceImage；音频素材另有 audioUrl、audioAssetId 两个单项参数，assets 里的资源 id 需匹配 `^[A-Za-z][A-Za-z0-9_-]{0,63}$`（:65）；
- 取回与改写都在 Node 侧完成：resolveAsset 把每个地址读成 Data URI 后注入源码（:606-638,727-755）；页面运行时，未预声明的网络请求一律被 installNetworkPolicy 拦截，只放行 about:blank、data:、blob: 与白名单 URL（:933-948）；
- 资源与地址约束：单资源 50MB、合计 100MB、每步不超过 24 个（:27-29,242,655,731）；远程下载逐跳复检重定向，最多 5 跳（:565-604）；云元数据地址 169.254.169.254、100.100.100.200、fd00:ec2::254 常禁，私网地址默认允许、可配 `AllowPrivateNetworkAssets=false` 关闭，URL 不允许携带用户名密码（:500-535）；
- 脚本白名单：外部脚本只有 jsDelivr、unpkg、cdnjs 上路径匹配 Anime.js、Three.js、Pixi.js 的标签会被识别，命中后替换成本地 vendor 目录（AdminPanel-Vue/vendor/）下的脚本，其余一律拒绝；libraries 兼容参数只接受 anime、three、pixi 三个库，pixijs 之类的前缀别名归一到 pixi。Pixi.js 绑定 v8 并挂在 window.PIXI 上，调用时必须用异步的 app.init(...)，停掉自带 Ticker，并在逐帧回调里显式 app.render()，才能与确定性逻辑时间轴对齐。白名单登记、URL 识别、标签改写与拒绝逻辑见 `MediaRenderer.js:80-90,247-255,286-293,768`。

被扫描的元素与属性全集：

```text
<img/video/audio/source/track/link/input/use> 的 src/poster/href/xlink:href、srcset，CSS url()
```

**执行位置**：不同媒体能力落在各自独立的执行域。
- 静态图与动画：交托管 Chrome 渲染。服务端要求根配置 `VCP_BROWSER_RUNTIME_ENABLED=true`（默认 false）才会启动浏览器，随后用 Puppeteer 走 CDP 连接，为每次渲染开独立的 browser context 和页面；截图由 sharp 编码成目标图片格式（:979-1006,1366-1370,1551-1569）。
- 动画编码：交 FFmpeg 按目标格式选参数。GIF 走 palettegen/paletteuse 调色板优化并配 sierra2_4a；MP4 用 H.264（libx264）配 yuv420p，加 `+faststart` 便于流式播放；WebM 用 libvpx-vp9，透明场景切 yuva420p；带音频轨时循环混流并以较短轨截止。首次编码前探测 `ffmpeg -version` 并缓存结果，参数构建与单次超时（FfmpegTimeoutMs，默认 180s）见 :1179-1236。
- 音频：在独立 Node 子进程中运行，不依赖 FFmpeg、浏览器或第三方 npm；spawn 不经 shell，超时后用 Windows taskkill 杀进程树（:1051-1069,1071-1145）。
- 图像与视频插件：调外部模型 API（SiliconFlow、OpenAI 兼容渠道、Gemini 等，完整清单见下方插件族盘点表），一律以 stdio 子进程执行，由 executePlugin 按 manifest 拼出入口命令并注入插件环境变量与 VCP 环境（`Plugin.js:1472-1583`）。

**图像插件族盘点（16 个插件目录，node 解析 manifest 确认；MediaRenderer 因两组命令分两行列示）**：

| 插件 | 类型 | 命令 | 外部依赖 |
|---|---|---|---|
| FluxGen | synchronous/stdio | FluxGenerateImage（文生图） | SiliconFlow API key |
| GPTImageGen | synchronous/stdio | GPTGenerateImage / GPTEditImage | OpenAI 兼容 API，内置 429/503 指数退避重试 |
| GeminiImageGen | synchronous/stdio | GeminiGenerateImage / GeminiEditImage | Gemini 兼容 API |
| QwenImageGen | synchronous/stdio | GenerateImage / EditImage | Qwen API |
| DoubaoGen | synchronous/stdio | DoubaoGenerateImage | Doubao API |
| DMXDoubaoGen | synchronous/stdio | DoubaoGenerateImage / Edit / ComposeImage | Doubao API |
| NanoBananaGen2 | synchronous/stdio | NanoBananaGenerate / Edit / Compose | 兼容 /v1/chat/completions，多渠道绑定轮询（URL+KEY+MODEL） |
| ZImageTurboGen | synchronous/stdio | GenerateImage（generate/edit/compose 合一） | Gitee 图像接口（每日免费 100 点额度声明） |
| AgnesGen | synchronous/stdio | GenerateImage（generate/edit/compose 合一） | Agnes/Sapiens API |
| ZImageGen2 | **.block 禁用** | ZImageGenerate | — |
| ComfyUIGen | **.block 禁用** | ComfyUIGenerateImage | 外部 ComfyUI（含 workflow-template-cli） |
| AgnesVideoGen | asynchronous/stdio | submit / query / concat | Agnes Video API；concat 走本地 ffmpeg 重编码 |
| VideoGenerator（Wan2.1VideoGen） | asynchronous/stdio（python） | submit / query | SiliconFlow Wan2.1；后台轮询+回调回注；`webSocketPush` video_generation_status |
| MimoDubbing | asynchronous/stdio | submitSequence / submit / query | 小米 MiMo 语音大模型（DMXAPI 或官方端点）；SRT/WebVTT/JSON 时间轴 → 24kHz 单声道 WAV；本地 ffmpeg 合成 |
| ImageFileServer | service/direct | 图片/文件静态托管 | 无（本机路径） |
| MediaRenderer | hybridservice/direct | RenderImage / RenderAnimation / GenerateAudio | 托管 Chrome + FFmpeg + sharp/puppeteer/mime-types |
| MediaRenderer | hybridservice/direct | GenerateCursorTheme | 托管 Chrome + sharp；编码 CUR/ANI 与 ZIP，不依赖外部模型 API |

## 3. 任务状态、异步回调与取消

- **同步插件**（图像族、MediaRenderer 渲染与音频）：一次 stdio 或 direct 调用就返回结果，没有任务状态对象可查。MediaRenderer 的渲染请求在进程内排队串行执行，没有取消接口，中断只能靠 manifest 声明的超时或单步超时兜底；超时对音频子进程杀进程树，对 FFmpeg 直接 SIGKILL（:1008-1049,1109-1112,1654-1658）。
- **异步视频插件有两条模式**（源码事实）：
  1. AgnesVideoGen 的 submit 在秒级返回 task_id，插件自身不回传回调，模型只能靠 query 反复轮询；完成后插件把视频下载到本地文件服务并给出 URL，concat 是同步的 ffmpeg 重编码拼接（AgnesVideoGen.mjs:206-275,406-445）。每次查询返回一种状态文本，取值与含义如下：
     - `queued`：任务排队中
     - `in_progress`：正在处理
     - `completed`：已完成
     - `failed`：已失败
  2. VideoGenerator（Wan2.1）的 submit 返回 requestId 后，插件内线程持续轮询外部 API，成功、失败或轮询超时都会触发回调；模型被要求在回复中保留异步结果占位符，后续请求由消息处理器读 `VCPAsyncResults/` 下对应文件替换成结果文本，文件尚未生成时替换为"结果待更新..."；manifest 打开 webSocketPush 时另经服务端广播 video_generation_status 事件（video_handler.py:214-302、modules/messageProcessor.js:830-868、server.js:1500-1512）。
- **回调端点**：`POST /plugin-callback/:pluginName/:taskId` 收到回调后写一份 JSON 文件，按配置做 WS 推送；端点不校验身份，服务端对 `/plugin-callback` 路径豁免 Bearer，taskId 也不带签名，与独特功能笔记能力五的边界记录一致。分布式节点回调由 handleDistributedPluginCallback 落到同一目录（server.js:1471-1515,870-873、WebSocketServer.js:95-144）。
- **取消**：全链路无用户/模型可发起的任务取消；无重启恢复语义（服务重启后异步结果文件仍在、可被占位符读取，但生成中任务不会续跑）。

## 4. 结果、历史、资产与工程持久化

- **结果**：产物文件按类型落 `image/`（图片与 GIF）与 `file/`（MP4/WebM/WAV），访问 URL 形如 `<VarHttpUrl>:<port>/pw=<key>/images|files/media-renderer/<name>`。写文件与拼接 URL 都由 saveArtifact 完成，其中访问密钥取自 ImageServer 插件配置、由 Plugin.js 注入，打开 showBase64 后还会额外内联一份 Data URI（MediaRenderer.js:1320-1352,1448-1455、Plugin.js:1520-1527）。图像与视频插件各自写入自己的子目录，并自行构造 URL。
- **历史**：没有媒体创作历史对象，既无会话绑定记录，也无媒体任务表；图像插件的结果不带持久化的调用参数记录。
- **资产命名与去重**：`<stem>-<时间戳>-<3字节随机>.<ext>`（MediaRenderer.js:1323），没有去重、索引或来源关联；同名请求每次都生成新文件。`file://` 本地素材跨请求复用的是原路径，产物复用靠 URL。
- **工程对象**：没有节点图或工程文件；ComfyUIGen 的 workflow-template-cli 属禁用插件，其对象是外部 ComfyUI 的配置，落在 VCPToolBox 媒体工程范围之外。
- **持久化服务**：ImageFileServer 以 service 插件形式提供受密码保护的静态托管，路径前缀为 `/pw=[key]/images|files/...`，对应 manifest 中的两个服务声明（ProtectedImageHosting 与 ProtectedFileHosting）；服务端对 `/pw=` 路径豁免 Bearer 校验，改用路径中的 key 鉴权（server.js:860-868）。产物即文件，重启后仍可访问。

## 5. 预览、编辑、重试、分支与复用

- **预览**：无项目内媒体查看器/画廊；预览由**模型在消息里渲染**——插件返回文本中带 `<img src="URL">` / `<video controls autoplay loop>` / `<audio controls>` 展示提示（MediaRenderer.js:1426-1431,1631），实际展示依赖客户端聊天端解析 HTML 片段（属消息渲染器类目，本页不展开）。
- **编辑**：两路——① 图像插件原生的图生图/修图/合成命令（各插件命令见第 2 节插件族盘点表），输入支持 http/file/data URI 与多图数组；② MediaRenderer 改源码重渲染（无编辑器，靠模型改 HTML/参数再调用）。
- **重试/分支**：无 UI 级重试/分支对象；Agent 可重新发起工具调用（等价重试），改参数重渲（等价分支）。Wan2.1/Agnes 的 `query` 可反复查询同一 job。
- **导出/分享**：一般产物即文件服务 URL，可直接外链/下载；鼠标主题是例外，会生成可下载 ZIP，同时将源 HTML、预览与安装/卸载脚本放入压缩包，但没有项目内主题库或导出历史。
- **复用**：URL 复用（见第 4 节）；无资产面板选择复用。

## 6. Agent 回流、插件协议与外部依赖

- **Agent 回流**：结果回到模型有两条路。异步任务靠占位符：模型在回复里保留 `{{VCP_ASYNC_RESULT::Plugin::id}}`，消息处理器在后续请求中把它换成结果文本，花括号兼容 2 至 4 层（modules/messageProcessor.js:830-868）；同步插件直接返回产物 URL。另有一路推送：manifest 打开 webSocketPush 的插件（Wan2.1 的 video_generation_status）会把进度与结果广播给 VCPLog 客户端（server.js:1500-1512）。
- **插件协议**（M4 编排）：Plugin.js 统一编排插件生命周期，媒体插件族覆盖四种类型——synchronous（图像族）、asynchronous（视频族）、hybridservice/direct（MediaRenderer）、service（ImageFileServer）。生命周期全集与三类分发、执行机制如下：
  - 生命周期全集：static、synchronous、asynchronous、service、messagePreprocessor、hybridservice；
  - hybridservice 分发：经 getServiceModule 直接调用模块的 processToolCall；带 requiresAdmin 的插件由 PluginManager 注入 `DECRYPTED_AUTH_CODE`，取不到码就拒绝执行（Plugin.js:1303-1334）。
  - stdio 子进程（图像与视频插件）：按 manifest 启动入口命令，参数以 JSON 经 stdin 传入；是否走 `shell:true` 由入口命令自身决定（Plugin.js:1577-1583）。
  - 异步插件：启动时注入 `CALLBACK_BASE_URL` 与 `PLUGIN_NAME_FOR_CALLBACK` 两个环境变量（Plugin.js:1553-1562）。
- **外部依赖边界**：下列各项都是运行前置条件，需在部署时自行准备。
  - 托管 Chrome 或 Edge：需 `VCP_BROWSER_RUNTIME_ENABLED=true` 且本机装有浏览器（MediaRenderer config.env.example:8-12）；
  - FFmpeg：放 PATH 或配置 `FfmpegPath`，只有动画与视频编码、拼接需要；
  - ImageFileServer 的 `Image_Key` 与 `File_Key`：产物托管必需，缺失时 saveArtifact 直接抛错（MediaRenderer.js:1324-1330）；
  - 各图像与视频插件的模型 API key，以及回调用的 CALLBACK_BASE_URL；
  - npm 依赖 puppeteer、sharp、mime-types：由根项目安装提供（MediaRenderer README:51），本快照仓库没有 node_modules。

## 7. 权限、资源边界与失败恢复

- **权限**：
  - 管理员权限：MediaRenderer 在 manifest 里声明 requiresAdmin 为 true，图像与视频插件没有这一要求；GenerateAudio 另加一道 6 位验证码比对，验证码取自 UserAuth 插件每小时轮换的码，经 PluginManager 解密后注入（MediaRenderer.js:451-463、Plugin.js:140-151，独特功能笔记能力十七）。
  - 文件服务：按 URL 路径里的 key 鉴权，即 `/pw=` 段。
  - 回调端点：不校验身份，详见第 3 节。
- **资源/大小限额**（常量定义见 MediaRenderer.js:16-40 与 AudioSynthesisWorker.js:5，均源码事实）：
  - 画布与源码：总像素 ≤4096²；源码 ≤2MB
  - 素材：单素材 ≤50MB、合计 ≤100MB、每步 ≤24 个
  - 批量：≤16 步串行
  - 动画：帧数 ≤`MaxAnimationFrames`（默认 600，上限 3600）
  - 音频：代码 ≤1MB、总采样 ≤3000 万、输出 ≤128MB、Worker 输出 ≤256KB、stdin ≤2MB
  - 超时：单步 ≤120s、FFmpeg 单次 ≤600s、音频子进程 ≤300s；超时杀进程树（Windows taskkill /T /F，:1051-1069）
- **执行域隔离**：AI 合成的代码只在独立 Node 子进程里运行，主服务自身不执行它；页面里的 JS 默认关闭，运行时网络被全量阻断；FFmpeg 以参数数组 spawn，不经过 shell。产物文件名先经 sanitizeFileStem 净化，再按服务类型固定落目录：图片与 GIF 进 `image/`，MP4/WebM/WAV 进 `file/`（MediaRenderer.js:282-290,1008-1014,1071-1145,1324-1335）。
- **失败恢复**：MediaRenderer 的 processToolCall 捕获所有异常，转成 `{status:'error', error, result:{text}}` 返回给调用方，不向上抛；FFmpeg 不可用时先有探测与缓存，再给明确报错；WAV 产物由主进程重新校验文件头、PCM 数据与时长（容差 ±2ms）；异步回调失败时插件侧把任务置为失败并回传；服务重启后 `VCPAsyncResults/` 里的文件仍在（无过期清理），占位符能继续读取，链路没有任务重试或恢复编排（MediaRenderer.js:1147-1177,1179-1194,1668-1677）。

## 8. 设计取舍、已确认边界与未验证事项

**设计取舍**：
- 媒体能力全部走 Agent 工具协议而非用户 UI：创作入口、参数清洁、结果展示都依赖模型遵循 manifest 契约，产物 URL 即持久化与复用介质，与 AIO Hub 桌面工作站、Chatbox 图像工作台的产品形态不同。
- 可编程渲染把"素材下载/校验"放在 Node 侧、把"渲染"放进无网络沙盒页面，页面运行时请求全部阻断——用预取换取渲染安全，代价是页面无法动态加载任何未声明资源（源码事实，`installNetworkPolicy` :933-948）。
- 确定性动画时间轴（绝对 timeMs 逐帧回调，不依赖真实时钟）保证机器负载不影响结果（manifest RenderAnimation 描述 + `encodeAnimation` :1260-1271）。
- 音频合成把 AI 生成的 DSP 代码交给独立 Node 子进程执行，给予完整 DSP 能力但以验证码与采样上限约束，产物由主进程二次校验。
- 异步回注以文件为事实源（VCPAsyncResults/），配合占位符在后续请求注入——与 MagiAgent、AgentAssistant 共用同一回注机制，但回调端点无鉴权（独特功能笔记能力五已记录，本页不重复展开）。

**已确认边界**：
- 媒体侧没有历史、资产库、去重索引、版本或工程对象，没有面向用户的媒体工作台与预览器，任务取消与重启恢复也没有对应入口。这次检索覆盖 `Plugin/` 下 16 个媒体插件目录、`Plugin.js`、`server.js` 与 `modules/messageProcessor.js`，这类模块均未找到。
- VCPDistributedServer 目录属于兄弟仓库 VCPChat；本快照内的分布式回注链是 `WebSocketServer.js:871` 处的 plugin_callback_forward 消息类型。
- README 声明的"复用根项目 Puppeteer/Sharp/mime-types"要求根项目先装好依赖，本机未安装（见下）。

**未验证事项**：
- MediaRenderer 真实渲染（托管 Chrome 需 `VCP_BROWSER_RUNTIME_ENABLED=true` 的完整服务器配置，未启动完整服务）；
- 外部模型真实生成（图像/视频插件均需 API key，按要求未申请）；
- 回调回注端到端（`VCPAsyncResults/` 落盘与占位符注入的完整请求链路未实测；独特功能笔记记载无测试覆盖）；
- `AllowPrivateNetworkAssets=false`、云元数据阻断、CDN 白名单在真实网络下的行为；
- 图像插件（GPTImageGen 等）对 file:// 素材转上传、重试退避的实际行为；
- 托管浏览器进程生命周期（空闲关闭、异常清理）与 MediaRenderer 的并发行为（renderQueue 串行）。

## 9. 关键源码索引

- 渲染器：`Plugin/MediaRenderer/MediaRenderer.js`（常量上限:16-40、CDN 白名单:42-64、页面协议:66-106、normalizeRequest:306、normalizeAudioRequest:391、验证码:451-463、云元数据:500-505、远程素材校验:507-535、素材解析:606-675、脚本白名单:677-696、直引 URL 收集:698-725、网络阻断:933-948、图片编码:979-1006、FFmpeg 探测:1179-1194、FFmpeg 参数:1196-1236、动画编码:1252-1296、产物托管:1320-1352、批处理:1489-1549、托管浏览器连接:1551-1569、音频执行:1608-1652、入口:1660-1678）
- 音频 Worker：`Plugin/MediaRenderer/AudioSynthesisWorker.js`（stdin 上限:5、synthesize 协议:145-156、确定性随机:72-81、WAV 编码:193-225）
- 插件协议与分发：`Plugin.js`（processToolCall:1164、hybridservice/direct+验证码注入:1303-1334、executePlugin 环境注入:1472-1583、异步插件 CALLBACK_BASE_URL:1553-1562）
- 回注链：`server.js:1471`（/plugin-callback）、`server.js:870-873`（鉴权豁免）、`modules/messageProcessor.js:830-868`（{{VCP_ASYNC_RESULT}}）、`WebSocketServer.js:95-144`（分布式回调转发）、`WebSocketServer.js:871`
- 图床/文件服务：`Plugin/ImageFileServer/image-file-server.js`、`server.js:860-868`（/pw= 路径豁免）
- 图像插件族：`Plugin/FluxGen/`、`GPTImageGen/`、`GeminiImageGen/`、`QwenImageGen/`、`DoubaoGen/`、`DMXDoubaoGen/`、`NanoBananaGen2/`、`ZImageTurboGen/`、`AgnesGen/`、`ZImageGen2/`(.block)、`ComfyUIGen/`(.block)
- 视频插件：`Plugin/AgnesVideoGen/AgnesVideoGen.mjs`（submit/query/concat）、`Plugin/VideoGenerator/video_handler.py`（poll_and_callback:214-302、占位符指引:440,465）
- 交接引用：`../独特功能/VCPToolBox-独特功能调查笔记.md`（能力五异步回注、能力十媒体插件族、能力十七 UserAuth）
