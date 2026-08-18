# VCPToolBox 媒体创作调查笔记

> 调查对象：`https://github.com/lioensky/VCPToolBox`（Node 服务端 + 插件架构）
>
> 调查更新日期：2026-08-14
>
> 代码快照：`1ae9b63c5afcea7677db5d71e5cf561a0f5debd9`（分支：`main`）
>
> 调查方式：只读源码梳理 + 尽力而为运行验证。通读 `Plugin/MediaRenderer/`（manifest、MediaRenderer.js 全文 1701 行、AudioSynthesisWorker.js、README、config.env.example），node 解析 15 个媒体插件 manifest，核对 `Plugin.js` hybridservice/asynchronous 分发、`server.js:1471` 回调端点、`modules/messageProcessor.js:827-867` 回注、`WebSocketServer.js:95-144` 分布式回调；运行验证含 `node --check`、音频 Worker 独立实测（成功与错误路径）、FFmpeg 按插件参数实测编码 GIF/MP4
>
> 调查范围：媒体创作类目视角（M2 可编程渲染、M4 插件编排、异步回注、资源白名单治理）；通用工具协议、Agent 审批、分布式任务等机制细节归并 Agent 工具类目；外部模型真实生成与托管浏览器渲染未运行（无 node_modules、无外部 key）
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPToolBox 的媒体创作能力是**服务端媒体供给/编排层**：项目本身没有最终用户媒体工作台或聊天 UI，Agent（模型）是主要创作者，通过 VCP 统一工具协议（`<<<[TOOL_REQUEST]>>>` + 中文「始」「末」边界符）调用媒体插件族。媒体主链由四类执行域构成：

1. **外部图像/视频模型 API 插件**（10 个启用的同步图像插件、2 个异步视频插件、2 个 `.block` 禁用插件），结果 URL 回注模型，由模型在消息中嵌入图片/视频/音频标签展示；
2. **MediaRenderer 可编程渲染**（hybridservice/direct，`requiresAdmin`）：HTML/SVG → 托管 Chrome 截图（静态图）或确定性逐帧 + FFmpeg 编码（GIF/MP4/WebM）；AI 合成代码 → Node 子进程生成 PCM16 WAV；
3. **ImageFileServer 图床/文件服务**：`/pw=[key]/images|files/...` 静态托管全部产物，是媒体结果的持久化真源；
4. **异步回注链**：异步视频插件（Wan2.1）后台轮询完成后回调 `/plugin-callback/:pluginName/:taskId` 端点，结果落盘为 `VCPAsyncResults/<plugin>-<taskId>.json`，后续请求经占位符注入上下文；分布式节点经 `plugin_callback_forward` 走同一条落盘链。

**核心边界**：媒体事实对象是"插件调用 + 产物文件 + 可选异步 job 文件"，**不存在**任务/历史/资产记录、去重索引、版本或用户可浏览的创作历史 UI；持续性与复用依赖文件服务 URL 的再次引用。资源白名单（单资源 50MB/总 100MB/每步 24 资源/源码 2MB/帧数上限/30M 采样数）、脚本白名单（仅内置 Anime.js/Three.js）、页面运行时网络全阻断、云元数据地址常禁、音频 requireAdmin 6 位验证码构成治理契约。

**证据分层**：全链为源码事实；`node --check` 通过、音频 Worker 成功/失败两路径实测、FFmpeg GIF/MP4 编码实测、15 份 manifest 解析通过（运行验证）；真实渲染输出、外部模型生成、回调端到端注入、托管浏览器进程行为未验证。

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

**完整主链（GenerateAudio）**：`command=generateaudio` 直调（MediaRenderer.js:1664-1666）：先比对 6 位验证码（:451-463），再做参数清洁（:391-449），随后 spawn 独立 Node 子进程（`node --max-old-space-size=512 AudioSynthesisWorker.js`，stdin 传 JSON）执行 AI 合成代码写出 PCM16 WAV；主进程重新校验 WAV 头、PCM 与时长（:1147-1177）后经 `saveArtifact` 进文件服务。

**完整主链（Wan2.1 视频异步回注）**：`submit` 提交外部 API 后立即返回 requestId，插件内起后台线程轮询终态（成功/失败/超时），完成后 POST 到 `{CALLBACK_BASE_URL}/{plugin_name}/{request_id}`；回调端点把结果写为 `VCPAsyncResults/Wan2.1VideoGen-<id>.json`，manifest 开启 `webSocketPush` 时另广播进度。模型被要求在回复中保留异步结果占位符，后续请求由消息处理器读该文件替换为结果文本（缺失时替换为"结果待更新..."）。轮询、回调地址注入、落盘与替换逻辑见 video_handler.py:214-302,440,465、Plugin.js:1553-1562、server.js:1471,1500-1512、modules/messageProcessor.js:830-868。

## 1. 创作入口、触发者与事实对象

- **入口**：无媒体专用 UI 入口。媒体能力全部以插件 manifest 的 `invocationCommands` 描述注入模型上下文，由 Agent 按文档输出工具块触发；管理面板只做插件启用/禁用（PluginManager 管理面），不提供创作入口。
- **触发者**：模型是主要创作者；用户通过对话间接触发（把需求写进提示词），不存在用户直接点按的生成按钮。任务提示假设的"独立聊天 UI"在本快照中不存在（VCPToolBox 是服务端中间层）。
- **事实对象**（三类，均无"记录"语义）：
  1. 插件调用（无持久化的调用记录对象，工具调用记录 `toolCallRecordStore` 属 Agent 工具类目）；
  2. 产物文件：`image/media-renderer/`（PNG/JPG/WebP/GIF）与 `file/media-renderer/`（MP4/WebM/WAV），命名 `<stem>-<Date.now()>-<3字节随机>.ext`（MediaRenderer.js:1323），图像插件写各自子目录（如 `image/fluxgen/`，见 FluxGen manifest 描述）；
  3. 异步 job 文件：`VCPAsyncResults/<pluginName>-<taskId>.json`（无过期清理，独特功能笔记能力五已记录）。

## 2. 参数、素材与模型/渲染执行

**参数进入请求**：VCP 工具块语法（中文「始」「末」边界符、英文逗号分隔参数），由 PluginManager 解析后按插件分发（`Plugin.js:1164` processToolCall）。manifest 描述即参数契约（`Plugin/MediaRenderer/plugin-manifest.json` 三命令含完整参数表与示例）。

**MediaRenderer 参数清洁（RenderImage/RenderAnimation，`normalizeRequest` MediaRenderer.js:306-389）**：
- 宽高必填 64-4096、总像素 ≤4096²（:318-321）；格式 png/jpg/webp/gif/mp4/webm，透明+JPG 自动改 PNG、透明+MP4 拒绝（:163-168）；
- 源码 html/svg 二选一且 ≤2MB（:309-316）；动画帧数 `ceil(durationMs×fps/1000)` ≤ `MaxAnimationFrames`（默认 600，上限 3600）（:345-355）；durationMs 100-60000、fps 1-60、waitMs ≤10000、timeoutMs 1000-120000（:328-343）；
- `allowJavaScript` 默认 false，动画/内置库/CDN 标签自动开启（:340-341）；JS 运行与否由此静态开关决定，非运行时判断；
- 批量：数字后缀参数（command1/html1/...）串行最多 16 步，公共参数作默认值（`collectSteps` :1512-1549）。

**素材进入请求（白名单预取）**：
- 直接写在源码的 URL：图片、视频、音频、字幕、链接与输入类元素的可寻址属性、`srcset` 和 CSS `url()`，由 `collectDirectSourceUrls` 收集（:698-725），完整元素/属性清单见本节末尾代码块；
- 兼容参数：`assets` JSON（资源 id 规则 `^[A-Za-z][A-Za-z0-9_-]{0,63}$`，:65）与 `sourceImage`；音频素材另有 `audioUrl`/`audioAssetId` 两个单项参数；
- 全部由 Node 侧 `resolveAsset`（:606-638）读取/下载为 Data URI 后注入源码（:727-755），Chromium 不直接访问本地文件或任意网络；页面运行时所有未预声明网络请求被拦截（`installNetworkPolicy` :933-948，仅放行 about:blank/data:/blob:/白名单 URL）；
- 资源上限：单资源 50MB、合计 100MB、每步不超过 24 个（:27-29,242,655,731）；HTTP 重定向逐跳复检、最多 5 跳（`downloadRemoteAsset` :565-604）；**云元数据地址常禁**（169.254.169.254、100.100.100.200、fd00:ec2::254）；私网地址默认允许、可通过 `AllowPrivateNetworkAssets=false` 关闭；URL 禁止带用户名密码（上述地址策略见 :500-505,512-514,517-533）。
- 脚本白名单：只有 jsDelivr/unpkg/cdnjs 上路径匹配的 Anime.js/Three.js 标签会被识别，并替换为本地 `AdminPanel-Vue/vendor/` 脚本；其他外部脚本一律拒绝。`libraries` 兼容参数也只接受这两个库。白名单定义、URL 识别、标签改写与拒绝逻辑见 MediaRenderer.js:47-64,172-187,194-219,677-696。

被扫描的元素与属性全集：

```text
<img/video/audio/source/track/link/input/use> 的 src/poster/href/xlink:href、srcset，CSS url()
```

**执行位置**：
- 静态图/动画：托管 Chrome（`browserRuntimeManager.ensureManagedBrowser()`，依赖根配置 `VCP_BROWSER_RUNTIME_ENABLED=true`，默认 false）→ Puppeteer CDP 连接（:1551-1569）→ 独立 browser context/页面（:1366-1370）；图片编码用 sharp（:979-1006）；
- 动画编码：FFmpeg 按目标格式选参数——GIF 用 palettegen/paletteuse 调色板优化（sierra2_4a），MP4 用 H.264（libx264）+ yuv420p 并加 `+faststart` 便于流式播放，WebM 用 libvpx-vp9（透明场景 yuva420p）；带音频轨时循环混流、以较短轨截止。首次编码前探测 `ffmpeg -version` 并缓存（:1179-1194），参数构建与单次超时（`FfmpegTimeoutMs` 默认 180s）见 :1196-1236；
- 音频：独立 Node 子进程（`runAudioWorker` :1071-1145，无 shell、Windows taskkill 杀进程树 :1051-1069），**不依赖 FFmpeg/浏览器/第三方 npm**；
- 图像/视频插件：外部模型 API（SiliconFlow、OpenAI 兼容渠道、Gemini 等，完整清单见下方插件族盘点表），全部以 stdio 子进程执行（`Plugin.js:1472-1583` executePlugin：spawn 入口命令、注入插件环境变量与 VCP 环境）。

**图像插件族盘点（15 目录，node 解析 manifest 确认）**：

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
| ImageFileServer | service/direct | 图片/文件静态托管 | 无（本机路径） |
| MediaRenderer | hybridservice/direct | RenderImage / RenderAnimation / GenerateAudio | 托管 Chrome + FFmpeg + sharp/puppeteer/mime-types |

## 3. 任务状态、异步回调与取消

- **同步插件**（图像族、MediaRenderer 渲染/音频）：单次 stdio/direct 调用返回结果，无任务状态对象；MediaRenderer 渲染队列 `renderQueue` 进程内串行（`enqueueRender` :1654-1658），无取消接口（中断只能靠 manifest/单步超时，超时对音频子进程杀进程树、对 FFmpeg SIGKILL，:1008-1049,1109-1112）。
- **异步视频插件两条模式**（源码事实）：
  1. AgnesVideoGen：`submit` 秒级返回 task_id，**插件自身不回传回调**，模型只能靠 `query` 反复轮询，按 queued（排队）、in_progress（进行中）、completed（完成）、failed（失败）四种状态返回文本；完成后插件下载视频到本地文件服务并返回 URL（AgnesVideoGen.mjs:206-275）；`concat` 是同步的 ffmpeg 重编码拼接（:406-445）；
  2. VideoGenerator（Wan2.1）：`submit` 返回 requestId 后，插件内线程 `poll_and_callback` 轮询外部 API，终态（Succeed/Failed/轮询超时）触发回调（video_handler.py:214-302）；模型被要求在回复中保留异步结果占位符，后续请求读 `VCPAsyncResults/` 下对应文件替换为结果文本（缺失时替换为"结果待更新..."，messageProcessor.js:830-868 的 :856-857）；manifest 中 `webSocketPush.enabled=true` 时经 server.js:1500-1512 广播 `video_generation_status` 事件。
- **回调端点**：`POST /plugin-callback/:pluginName/:taskId`（server.js:1471-1515）写 JSON 文件 + 可选 WS 推送；**无鉴权**（server.js:870-873 对 `/plugin-callback` 豁免 Bearer），taskId 无签名——与独特功能笔记能力五的边界记录一致。分布式节点回调经 `handleDistributedPluginCallback`（WebSocketServer.js:95-144）落同一目录。
- **取消**：全链路无用户/模型可发起的任务取消；无重启恢复语义（服务重启后异步结果文件仍在、可被占位符读取，但生成中任务不会续跑）。

## 4. 结果、历史、资产与工程持久化

- **结果**：产物文件落 `image/`（图片/GIF）与 `file/`（MP4/WebM/WAV），URL 形态 `<VarHttpUrl>:<port>/pw=<key>/images|files/media-renderer/<name>`；写入与 URL 构造由 `saveArtifact` 完成（MediaRenderer.js:1320-1352），访问密钥来自 ImageServer 插件配置、经 Plugin.js:1520-1527 注入，静态图片可开启 `showBase64=true` 额外内联 Data URI（:1448-1455）。图像/视频插件则各自写入自己的子目录并自行构造 URL。
- **历史**：**不存在**媒体创作历史对象（无会话绑定记录、无媒体任务表）；图像插件结果不带持久化调用参数记录。
- **资产命名与去重**：`<stem>-<时间戳>-<3字节随机>.<ext>`（MediaRenderer.js:1323）——**无去重、无索引、无来源关联**；同名请求每次生成新文件。`file://` 本地素材跨请求复用的是原路径，产物复用靠 URL。
- **工程对象**：不存在（无节点图/工程文件；ComfyUIGen 的 workflow-template-cli 属禁用插件且对象是外部 ComfyUI 配置，非 VCPToolBox 媒体工程）。
- **持久化服务**：ImageFileServer（service 插件）以 `/pw=[key]/images|files/...` 提供受密码保护的静态托管，对应 manifest 中的 `ProtectedImageHosting`/`ProtectedFileHosting` 两个服务声明；server.js:860-868 对 `/pw=` 路径豁免 Bearer、改用路径中的 key 鉴权。产物即文件，重启后可访问。

## 5. 预览、编辑、重试、分支与复用

- **预览**：无项目内媒体查看器/画廊；预览由**模型在消息里渲染**——插件返回文本中带 `<img src="URL">` / `<video controls autoplay loop>` / `<audio controls>` 展示提示（MediaRenderer.js:1426-1431,1631），实际展示依赖客户端聊天端解析 HTML 片段（属消息渲染器类目，本页不展开）。
- **编辑**：两路——① 图像插件原生的图生图/修图/合成命令（各插件命令见第 2 节插件族盘点表），输入支持 http/file/data URI 与多图数组；② MediaRenderer 改源码重渲染（无编辑器，靠模型改 HTML/参数再调用）。
- **重试/分支**：无 UI 级重试/分支对象；Agent 可重新发起工具调用（等价重试），改参数重渲（等价分支）。Wan2.1/Agnes 的 `query` 可反复查询同一 job。
- **导出/分享**：产物即文件服务 URL，可直接外链/下载；无打包导出。
- **复用**：URL 复用（见第 4 节）；无资产面板选择复用。

## 6. Agent 回流、插件协议与外部依赖

- **Agent 回流**：`{{VCP_ASYNC_RESULT::Plugin::id}}` 占位符（messageProcessor.js:830-868，兼容 2/3/4 层花括号）与直接 URL 回注；`webSocketPush`（Wan2.1 的 `video_generation_status`）向 VCPLog 客户端广播进度/结果（server.js:1500-1512）。
- **插件协议**（M4 编排）：`Plugin.js` 统一编排插件生命周期，媒体插件族使用其中四类：synchronous（图像族）、asynchronous（视频族）、hybridservice/direct（MediaRenderer）、service（ImageFileServer）。生命周期全集与三类分发/执行机制如下：
  - 生命周期全集：static、synchronous、asynchronous、service、messagePreprocessor、hybridservice；
  - hybridservice 分发：经 `getServiceModule` 直接调用模块的 `processToolCall`（Plugin.js:1303-1334）；`requiresAdmin` 插件由 PluginManager 注入 `DECRYPTED_AUTH_CODE`（:1318-1327），取不到码即拒绝执行；
  - stdio 子进程（图像/视频插件）：spawn 入口命令、参数经 stdin JSON 传递（:1577-1583），`shell:true` 与否由入口命令自身决定；
  - 异步插件：注入 `CALLBACK_BASE_URL` 与 `PLUGIN_NAME_FOR_CALLBACK`（:1553-1562）。
- **外部依赖边界**（按类别列出，均属运行前置而非开箱可用）：
  - 托管 Chrome/Edge（`VCP_BROWSER_RUNTIME_ENABLED=true` 且本机装有浏览器，MediaRenderer config.env.example:8-12）；
  - FFmpeg（PATH 或 `FfmpegPath`，仅动画/视频编码/拼接需要）；
  - ImageFileServer `Image_Key`/`File_Key`（产物托管必需，缺失时 `saveArtifact` 抛错，MediaRenderer.js:1324-1330）；
  - 各图像/视频插件的模型 API key 与 `CALLBACK_BASE_URL`；
  - npm 依赖 puppeteer/sharp/mime-types（复用根项目依赖，MediaRenderer README:51；本快照仓库无 node_modules）。

## 7. 权限、资源边界与失败恢复

- **权限**：
  - `requiresAdmin`：MediaRenderer manifest 声明 true；图像/视频插件无 requiresAdmin；GenerateAudio 强制 6 位验证码比对（MediaRenderer.js:451-463，验证码来源=UserAuth 插件每小时轮换码经 Plugin.js:140-151 解密注入，独特功能笔记能力十七）；
  - 文件服务：路径 key（`/pw=`）鉴权；
  - 回调端点无鉴权（见第 3 节）。
- **资源/大小限额**（常量定义见 MediaRenderer.js:16-40 与 AudioSynthesisWorker.js:5，均源码事实）：
  - 画布与源码：总像素 ≤4096²；源码 ≤2MB
  - 素材：单素材 ≤50MB、合计 ≤100MB、每步 ≤24 个
  - 批量：≤16 步串行
  - 动画：帧数 ≤`MaxAnimationFrames`（默认 600，上限 3600）
  - 音频：代码 ≤1MB、总采样 ≤3000 万、输出 ≤128MB、Worker 输出 ≤256KB、stdin ≤2MB
  - 超时：单步 ≤120s、FFmpeg 单次 ≤600s、音频子进程 ≤300s；超时杀进程树（Windows taskkill /T /F，:1051-1069）
- **执行域隔离**：AI 合成代码只在独立 Node 子进程运行（主服务不执行，MediaRenderer.js:1071-1145）；HTML 中的 JS 默认关闭、页面运行时网络全阻断；FFmpeg 以参数数组 spawn、不经 shell（:1008-1014）。产物文件经 `sanitizeFileStem` 净化命名（:282-290），并按服务类型固定落目录（图片/GIF→image/，MP4/WebM/WAV→file/，:1324-1335）。
- **失败恢复**：MediaRenderer `processToolCall` 捕获一切异常返回 `{status:'error', error, result:{text}}`（:1668-1677），不向上抛；FFmpeg 不可用有探测缓存与明确错误（:1179-1194）；WAV 结果主进程重新校验头/PCM/时长（±2ms，:1147-1177）；异步回调失败在插件侧置失败状态回传；服务重启后 `VCPAsyncResults/` 文件仍在（无过期清理），占位符可继续读取；无任务重试/恢复编排。

## 8. 设计取舍、已确认边界与未验证事项

**设计取舍**：
- 媒体能力全部走 Agent 工具协议而非用户 UI：创作入口、参数清洁、结果展示都依赖模型遵循 manifest 契约，产物 URL 即持久化与复用介质——这是"服务端供给层"定位的直接后果，与 AIO Hub 桌面工作站、Chatbox 图像工作台形成三种不同产品形态。
- 可编程渲染把"素材下载/校验"放在 Node 侧、把"渲染"放进无网络沙盒页面，页面运行时请求全部阻断——用预取换取渲染安全，代价是页面无法动态加载任何未声明资源（源码事实，`installNetworkPolicy` :933-948）。
- 确定性动画时间轴（绝对 timeMs 逐帧回调，不依赖真实时钟）保证机器负载不影响结果（manifest RenderAnimation 描述 + `encodeAnimation` :1260-1271）。
- 音频合成"代码即作品"：给 AI 完整 DSP 能力但限制在子进程+验证码+采样上限内，产物由主进程二次校验。
- 异步回注以文件为事实源（VCPAsyncResults/），配合占位符在后续请求注入——与 MagiAgent、AgentAssistant 共用同一回注机制，但回调端点无鉴权（独特功能笔记能力五已记录，本页不重复展开）。

**已确认边界**：
- 无媒体历史/资产库/去重索引/版本/工程对象；无用户媒体工作台与预览器；无任务取消与重启恢复（本次在 `Plugin/` 15 个媒体插件目录、`Plugin.js`、`server.js`、`modules/messageProcessor.js` 范围内搜索，未找到此类模块；不构成对仓库其他角落的绝对断言）。
- VCPDistributedServer 目录不在本仓库（属 VCPChat）；本快照内的分布式回注链是 `WebSocketServer.js:871` 的 `plugin_callback_forward` 消息类型。
- README 声明的"复用根项目 Puppeteer/Sharp/mime-types"依赖根项目安装依赖；本机未安装（见下）。

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
