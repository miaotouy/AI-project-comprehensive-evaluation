# Risuai 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/kwaroran/Risuai`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`39f1ac1472d0ef6907ee933c4cf25182ee2aec9f`（分支：`main`）
>
> 调查方式：静态代码审查；关键词 grep（inlay/iframe/sandbox/eval/Function/pyodide/lua/streaming/reroll 等）定位能力边界，通读生成主链（process/index.svelte.ts 的流式与最终化）、inlay 资产层（process/files/inlays.ts）、消息解析与净化管线（parser/parser.svelte.ts）、图像与语音产出（stableDiff.ts、tts.ts）、插件沙箱（plugins/ 与 apiV3/）、脚本引擎（scriptings.ts、pyworker.ts）及持久化入口（globalApi.svelte.ts、storage/、drive/）
>
> 调查范围：模型产出获得对象身份、专用表面、运行环境、编辑与持久化的整条链路；含 inlay 媒体资产、生成信息与重掷、图像生成协议、TTS、脚本与插件对输出的介入、持久化与回流。明确排除：对话请求类目的上下文装配与发送语义细节、消息渲染器的普通 Markdown 细节、MCP 与工具调度的执行语义、角色卡输入侧机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Risuai 与 SillyTavern 同为角色扮演聊天应用，输出模型以**消息正文文本为主体（G0）**，但比 SillyTavern 多出**唯一一类获得独立对象身份的输出：inlay 资产**（G1）。inlay 是存放于独立 IndexedDB（localforage 实例 `inlay`）的媒体对象，以 UUID 寻址，类型分 image/video/audio/signature，通过 `{{inlay::id}}` 这类文本占位符嵌入消息 `data`；模型可通过 `<ImgGen="prompt">` 标记、Gemini 原生媒体返回或脚本/触发器生成它们，插件 API 可读取，提示构建时图片与签名可回注模型上下文。除此之外，SD 图片在非 inlay 模式下写入角色立绘存储（`CharEmotion`），TTS 音频仅即时播放不落对象。

全仓检索与主链通读的结果停在 G1：没有声明式组件协议，模型输出也不进入任何执行环境（iframe 只用于插件自身 UI 与 YouTube 嵌入；Lua/Python 脚本引擎执行用户或角色维护的脚本，属于输入侧）。同样没有 artifact 工作区、画布或桌面挂件；VisualNovel 模式在 `AGENTS.md` 中有目录条目，全仓检索没有找到对应代码。reroll（重掷）是内存级的整条消息版本替换，不持久化。

## 系统边界与总体调用链

边界：生成、渲染、后处理、媒体生成全部在浏览器前端（Svelte 5 + TypeScript）完成；Tauri 仅提供文件系统、窗口与原生 fetch 等宿主能力；Node/Hono 服务提供数据存储与 API 代理。事实源是内存 `DBState.db`（角色、聊天、设置），保存时经 `RisuSaveEncoder` 序列化为 `database.bin` 写回存储后端；inlay 二进制另存于独立 localforage 实例，与主数据库分离（详见 §8）。

**主链路（触发 -> 生成 -> 展示 -> 保存 -> 重新打开）**：

1. 发送入口 `sendChat` 构造提示；消息进入上下文前先经 `processScriptFull` 的 editprocess 阶段处理，角色消息里的 inlay 占位在这一步按类型解析：图片、音频、视频转为多模态附件，签名对象转为 signature 附件，普通 inlay 引用被剥除（`src/ts/process/index.svelte.ts:99`、`900-974`）。
2. 请求默认走流式，从 1591 行起逐块读取；每个批次把累积文本交给 mode 为 editoutput 的输出脚本处理，然后整段覆盖消息对象的 `data` 字段，并自增 `reloadKeys` 触发 Svelte 重渲染，刷新节流与后处理时机由三档性能优化模式决定（`index.svelte.ts:1591` 起）。
3. 流结束后进入收口：先运行输出触发器，再由 `runInlayScreen` 把 `<ImgGen>` 与 `{{ImgGen}}` 标记替换为占位文本，异步生成的图片写入 inlay 后回填 `{{inlay::id}}`；随后运行聊天输出监听器，按设置决定是否自动 TTS 播报，并按结果 token 数决定是否自动续写（`index.svelte.ts:1775`）。
4. 保存时对内存数据库整体快照，经 500ms 防抖写入 `database.bin`；inlay 资产单独落到 IndexedDB（`src/ts/globalApi.svelte.ts:292`）。
5. 重新打开时，启动阶段读回 `database.bin` 重建内存库，消息文本保留 inlay 占位，渲染时由 `ParseMarkdown` 把占位替换为 blob URL 指向的媒体。inlay 引用可以恢复，资产本体不随数据库文件迁移（见 §8 边界）。

## 1. 触发方式、输出协议与对象模型

- **触发与协议**：模型只有自由文本一条内容通道，宿主用正则和标记从文本里识别产出意图，没有结构化的输出对象协议。
  - `<ImgGen="提示词">` 与 `{{ImgGen="提示词"}}`：inlay 视图模式（imggen）下的图像生成标记，生成时先替换为 `[Generating...]`，图片落 inlay 后回填占位（`src/ts/process/inlayScreen.ts:7-49`）；
  - `<Emotion="名称">`：emotion 视图模式下的表情标记，先替换为 `{{emotion::名称}}`，再经 CBS 宏解析成角色表情图；
  - Gemini 响应中的 `thoughtSignature` 与 `inlineData`：签名与内联媒体直接落 inlay（`src/ts/process/request/google.ts:722-759`）；
  - `<Thoughts>` 与 `<tool_call>`：展示层折叠块与工具调用卡片，不产生对象。
  这些标记都按整段文本做正则探测，没有转义处理或嵌套状态机；误触发的防护来自正则本身，以及用 Unicode 私有区字符保护花括号与圆括号的转义函数（`src/ts/parser/parser.svelte.ts:713-734,133-150`）。
- **对象模型**：三类对象获得独立身份。
  - **消息**：`Message` 类型定义在 `src/ts/storage/database.svelte.ts:1848`，记录角色归属、正文（含 inlay 占位）、发言标记，以及发送前补齐的 v4 UUID、时间戳、生成信息与提示信息；内存数组是事实源，经 `database.bin` 持久化，DOM 每次由对象重渲。
  - **Inlay 资产**：`InlayAsset` 定义于 `src/ts/process/files/inlays.ts:8-16,30-33`，字段包括二进制数据（Blob 或 base64）、扩展名、名称、类型（image/video/audio/signature）以及可选的宽高，键为 v4 UUID，存放在独立的 localforage 实例里。消息用三种占位引用它：`{{inlay::id}}` 内联渲染，`{{inlayed::id}}` 与 `{{inlayeddata::id}}` 走带 risu-inlay-image 容器的展示。资产记录里没有来源消息、创建者或版本字段，聊天文件与资产库之间只靠文本占位的字符串匹配关联，没有反向索引。
  - **生成信息**：`MessageGenerationInfo` 定义于 `database.svelte.ts:1862`，记录 `generationId`（即消息 chatId）、模型、输入与输出 token、上下文上限以及四段阶段计时，随消息一起持久化，供 reroll 定位与信息展示。
- **无对象形态的产出**：TTS 音频解码后立即播放、不保存对象（`src/ts/process/tts.ts:68-78`）；非 inlay 模式的 SD 图片写入角色立绘存储 `CharEmotion`，只挂当前角色，与来源消息没有关联（`stableDiff.ts:102-108` 等分支）。

## 2. 增量生成、更新与最终化

- **更新粒度**：整段重写，没有节点级 diff。流式循环把每个 chunk 的累积文本经 editoutput 脚本处理后直接赋给消息 `data`，不做 AST 或节点 patch（`index.svelte.ts:1716-1719`）。性能优化模式 `streamingDisplayOptimizationMode` 分三档：
  - off：每个 chunk 都做全量后处理；
  - balanced：用 125ms 定时器合并刷新，再在请求动画帧里批量提交；
  - strong：推迟后处理，先以纯文本渲染原始流，流结束后补跑一次 editoutput（`src/lib/ChatScreens/ChatBody.svelte:261-268`、`index.svelte.ts:1738-1745`）。
- **半截流**：开启 `removeIncompleteResponse` 时，`trimUntilPunctuation` 把未完成输出截断到最后一个标点（`index.svelte.ts:1708-1710`）。解析失败各有兜底：KaTeX 报错时保留原文，CSS 解析失败按设置返回空字符串或错误文本（`src/ts/parser/parser.svelte.ts:174-177`、`961-966`）。
- **最终化**：流结束或非流式响应直接返回后，按顺序执行五个步骤（`index.svelte.ts:1763-1904`）：
  1. 运行输出触发器 `runTrigger`，它可以改写消息，也可以要求重发；
  2. 由 `runInlayScreen` 异步生成图片并回填占位；
  3. 触发聊天输出监听器 `runChatOutputListeners`，交给插件与自定义钩子；
  4. 按设置自动播报 TTS（`ttsAutoSpeech`）；
  5. 判定自动续写：结果 token 过少或结尾没有标点，就递归调用 `sendChat(..., {continue: true})`。
- **失败收口**：错误处理入口在开启 `inlayErrorResponse` 时把错误文本以 `risuerror` 代码块写进消息正文，关闭时改为弹窗；流中止经 AbortController 与 reader.cancel 完成，中止后丢弃未完成的消息，已写入的文本保留（`src/ts/process/index.svelte.ts:159-210,1682-1686`）。

## 3. 投影表面与多视图关系

- **消息正文**：唯一主表面。消息组件对拼装好的展示文本执行 `ParseMarkdown`，再以 `{@html}` 注入 DOM；开启翻译时注入的是译后 HTML，源文本仍保存在消息 data 中（`src/lib/ChatScreens/ChatBody.svelte:249-268`）。
- **立绘/背景层**：`EmotionBox.svelte` 从 `CharEmotion` store 取图渲染角色立绘，是非 inlay 模式 SD 输出的投影面；`BackgroundDom.svelte` 把 `backgroundHTML` 资产渲染为消息底层背景（`src/lib/ChatScreens/EmotionBox.svelte:8-13`）。
- **Playground（开发者工具区）**：`PlaygroundInlayExplorer.svelte` 提供 inlay 资产的列表、预览与批量删除，另有图片生成与解析器试验页，是本类目唯一的对象管理器表面（`src/lib/Playground/PlaygroundInlayExplorer.svelte:52-79`）。
- 界面没有侧栏对象区、独立窗口或桌面挂件，Tauri 只承担宿主能力。同一 inlay 资产可被多条消息引用，构成这里唯一的「一对象多投影」形态。

## 4. 表现类型、依赖与运行环境

- **支持的层级**：渲染链由 markdown-it（开启 html）、按语言动态加载高亮的 highlight.js 与 KaTeX 组成，数学公式用 `$$...$$`；结果再经 DOMPurify 净化，模型产出的媒体通过 inlay 占位渲染成 `img`、`video controls` 与 `audio controls` 元素（`parser.svelte.ts:681-696`）。
- **净化边界**：DOMPurify 钩子与 `trimMarkdown` 白名单共同决定放行范围（`parser.svelte.ts:46-119`）：
  - iframe 只放行 `https://www.youtube.com/embed/` 前缀的 src，其余直接移除（`parser.svelte.ts:46-52`）；
  - class 一律加 `x-risu-` 前缀，`hljs` 与已带 `x-risu-` 的类保留；href 只允许 http(s)，并强制 `target=_blank`；
  - `<style>` 块先 hex 编码再经 CSS AST 解析：选择器加 x-risu- 前缀并作用域到 .chattext，`@import` 只接受空 data URI（`src/ts/parser/parser.svelte.ts:900-968`）；
  - 开启 `hideAllImages` 时隐藏外部图片与 background-image，下标与数学相关的 MathML 标签集保留（`trimMarkdown`，`parser.svelte.ts:779-799`）。
- **运行环境**：模型输出没有执行面。全仓的 `eval` 与 `new Function` 只出现在插件系统（见 §7），iframe 仅用于插件容器和 YouTube 嵌入，没有 WebView 或 worker 承载模型产出。Pyodide（`src/ts/process/pyworker.ts`）与 wasmoon Lua 引擎执行的是脚本系统代码，由用户或角色在输入侧维护。
- 全仓 grep 没有命中 Mermaid 或图表渲染、Canvas 输出、HTML 小应用、可下载代码项目等层级的渲染管线。

## 5. 用户交互、事件与错误反馈

- **消息级操作**：复制（解析后 HTML 或源文本）、编辑、删除、翻译、TTS 播放以及 reroll 前进后退都由宿主固定按钮提供，模型无法声明这些操作（`src/lib/ChatScreens/Chat.svelte:743-763`、`796-809`）。`PartialEditController.svelte` 提供块级与拖选式局部编辑和删除，保存时整段回写消息 `data`（同文件 133-139 行）。
- **事件回传**：插件以 `addRisuChatListener('output', ...)` 订阅输出（`src/ts/plugins/apiV3/v3.svelte.ts:733-740`）；自定义 Lua 脚本经编辑触发器在四种模式下改写文本；插件还可注册 TTS 前处理与后处理钩子，用来替换音频、改 mime 或跳过播放，钩子带超时与容错（`src/ts/process/ttsHooks.ts:29-48,61-105`）。
- **错误反馈**：生成、图片与 TTS 错误以 toast 和消息内的 `risuerror` 代码块呈现，`<tool_call>` 渲染为消息内卡片。
- 流式性能模式 strong 下走 `renderRawStreaming` 入口这一点由源码确认，实际渲染效果未经运行验证。

## 6. 编辑、diff、版本与协作

- **编辑**：全文覆盖式。编辑保存直接覆写消息 `data`，局部编辑也整段覆盖。译文视图下的局部编辑改写翻译缓存，原消息保持原样，缓存修订会触发该视图重新解析；原文与译文两种编辑态互斥（`Chat.svelte:136-276,498-546`、`PartialEditController.svelte:18-63,238-307`）。编辑后 inlay 占位符是否保留取决于用户操作，系统不校验引用完整性。
- **版本**：reroll 是唯一的版本机制，作用范围限于内存。生成过程中 `addRerolls` 按 chunk 累积各候选文本，reroll 时用 `safeStructuredClone` 快照整段消息数组并整体替换（`src/ts/process/prereroll.ts:26-29`、`DefaultChatScreen.svelte:218-317`），内容不落盘，刷新即失。没有 diff、patch、接受/拒绝或分支。
- **协作**：应用面向单用户本地使用，没有协作能力；云同步（drive）只同步主数据库与 assets（见 §8），不涉及对象级冲突处理。

## 7. 能力桥、执行位置与权限范围

- **执行位置**：模型输出只在宿主 DOM 中渲染，没有脚本执行环节。插件系统分两代：
  - API 3.0：插件代码在隐藏 iframe 内经 `eval('(async () => ...)')` 运行，与宿主通过 postMessage 桥通信；sandbox 放行脚本执行、模态框与下载三项权限，并带 CSP（`src/ts/plugins/apiV3/factory.ts:296,771-788,921`）。iframe 默认隐藏，调用容器放大接口可把 iframe 放大到全屏 UI（`v3.svelte.ts:967-994`）。
  - API 2.1：存量插件仍在主线程通过 `new Function` 执行，执行前先经 `checkCodeSafety` 静态改写；新的 2.1 插件导入已被拒绝（`src/ts/plugins/plugins.svelte.ts:343-361,890-910`）。
  插件 iframe 承载插件自身的 UI 与代码，模型文本不会注入其中执行。
- **能力桥**：插件 API 能读取 inlay、读写数据库、发起网络请求、注册输出监听器与 replacer；脚本引擎（Lua/Python）可调用 `generateImage` 生成图片并写入 inlay（`src/ts/process/scriptings.ts:392-404`），触发脚本另有对应的图像生成效果（`src/ts/process/triggers.ts:1539-1557`）。这些桥接由脚本作者（用户或角色）预编译，模型只能通过文本标记间接驱动。v3 中读取 inlay 与注册输出监听器分别取得 inlay 或 replacer 权限，并按插件名、脚本哈希和三天周期复核，其余权限在插件权限查询的 API 调用点判定（`v3.svelte.ts:569-627,733-753`）。
- 模型输出侧没有网络、存储或宿主动作的权限声明：媒体引用只解析到已存在的资产，外部图片地址不会被加载执行，只能作为 img 标签显示，并受 `hideAllImages` 控制。

## 8. 持久化、恢复、分享与导出

- **主库**：内存中的数据库状态对象经 `RisuSaveEncoder` 序列化为 `database.bin`，写入带 500ms 防抖和多备份轮换（`src/ts/globalApi.svelte.ts:292-525`）；后端抽象覆盖 Tauri FS、LocalForage、Node 服务与账户存储。消息的正文（含 inlay 占位）、生成信息与提示信息全部随主库往返。
- **inlay 资产库**：inlay 存放于独立的 localforage 实例（IndexedDB 库名 `inlay`），与主库分离。恢复消息时占位符能够解析，资产本体不随 `database.bin` 备份或迁移，也不在 drive 同步范围内，同步只枚举主存储的 keys（`src/ts/drive/drive.ts:156-169`）。冷存储归档旧聊天时同样只归档消息文本（`src/ts/process/coldstorage.svelte.ts:575`），inlay 二进制不在归档 payload 中（`coldstorageData.ts` 仅替换资源路径）。跨设备或重装后 inlay 媒体丢失、占位保留，这一点属静态推断，未经运行验证。
- **分享/导出**：角色卡导出与导入（.risum/.risup/.charx）不携带 inlay 资产；正则脚本可导出为单文件 JSON（`scripts.ts:30-39`）。聊天导出入口在本次调查中没有找到，Playground 与数据管理面未逐一核对。删除 inlay 的常规入口只有 PlaygroundInlayExplorer 的逐项或批量删除，没有按引用清理与孤儿回收。

## 9. 模型回流、对象感知与持续维护

- **提示构建时的 inlay 解析**（`index.svelte.ts:900-974`）：角色消息中 `{{inlayeddata::id}}` 按资产类型回注——图片转为 multimodal 附件（模型支持图像输入时）或经本地图像描述模型生成文字附注；video/audio 转为多模态附件；signature 转为 signature 附件（Gemini 签名校验链）。`{{inlay::}}`/`{{inlayed::}}` 在角色消息中被剥除，而用户消息中的 inlay 引用会解析为多模态附件。
- **持续维护的对象**：无。模型不能查询 inlay 列表或定向修改某个资产；下一轮上下文里图片以 base64 附件或描述文本形式重新出现，但模型无从得知其 UUID 或"同一个对象"概念。reroll 候选不回流。记忆系统（Hypa/Supa 等）属输入侧维护的摘要文本，不面向输出对象。
- **结论**：对象感知仅存在于"宿主程序在提示侧代取内容"这一层，模型本身无寻址能力；不属于 G5 意义上的环境化活对象。

## 10. 生命周期、资源治理与性能

- **inlay 资产**：资产层缺少引用计数、自动回收与孤儿清理。渲染侧把 blob URL 缓存在 `blobUrlCache`，生命周期跟随页面会话，除 Playground 手动删除时单独 revoke 外，没有找到其他释放逻辑（`parser.svelte.ts:664-680`）。
- **TTS**：模块级单例 `sourceNode` 持有当前播放源，由 `stopTTS()` 停止（`tts.ts:431-438`）；AudioContext 每次播放都新建，没有统一的关闭与计数逻辑。
- **脚本引擎**：Lua 引擎与 Pyodide 上下文按 mode 复用，代码变更时关闭旧实例再重建（`scriptings.ts:84-104`）；脚本请求另有每分钟限额（`scriptings.ts:336` 附近）。
- **生成侧**：流式刷新按性能模式节流，balanced 档为 125ms 定时器加请求动画帧（`index.svelte.ts:1628-1681`）；中止经 AbortController 完成；自动续写与输出触发器重发共用同一个 abortSignal，两者都递归调用 `sendChat`，调用链可能拉得很长，代码里没有显式的递归上限。
- 不可见消息不会冻结，仍以静态 HTML 存在，系统没有对象级的暂停或冻结策略；长会话的限额集中在输入侧，包括上下文 token 预算与脚本请求限额。

## 11. 测试、已确认边界与未验证事项

- **测试现状**：测试框架为 vitest，入口 `pnpm test`，已覆盖的范围包括：
  - inlay 存储 CRUD 与迁移（`src/ts/process/files/tests/inlays.test.ts`）；
  - TTS 钩子管线（`ttsHooks.test.ts`）与脚本系统（`scriptings.test.ts`）；
  - 解析器的 chatML、chatVar、CBS 条件/转义/循环（`src/ts/parser/tests/`）；
  - 冷存储数据、翻译正则（`edittransRegex.test.ts`）。
  针对流式管线、提示构建 inlay 回注、净化与渲染链路、reroll 交互的测试均未找到，也没有 E2E 用例。类型检查用 `pnpm check`（svelte-check）。以上测试均未运行。
- **已确认边界**（源码直接确认）：
  - 模型输出没有执行面：`eval` 与 `new Function` 的命中全部在插件系统内，v2.1 走主线程、v3 在 iframe 内，执行的都是插件代码；iframe 只用于插件容器与 YouTube 嵌入（`parser.svelte.ts:46-52`）。
  - 没有 artifact、画布、工作区或桌面输出表面；`Canvas` 只用于 inlay 图片缩放与压缩（`inlays.ts:83-125`）。
  - VisualNovel 模式：`AGENTS.md` 的目录结构条目列出 `src/lib/VisualNovel/`，而 `src` 全目录 glob 与内容搜索（VisualNovel、visual novel 等大小写变体）没有命中，只在 `src/ts/iris.ts:86` 的提示词文本里出现 "visual novel style" 字样；按当前代码快照判定，该能力没有对应实现。
  - reroll 为内存级版本替换，不持久化。
  - inlay 资产不随 `database.bin`、drive 同步与冷存储迁移。
- **推断**（基于静态代码）：inlay 跨设备丢失行为、流式性能模式的实际渲染效果、插件 iframe 桥的完整可用性、自动续写链在长会话中的行为都属于推断。
- **未验证事项**：应用与测试均未运行；消息气泡、立绘、Playground 列表、iframe UI、TTS 播放等 DOM 行为，以及浏览器端 IndexedDB 行为，都还没有经过运行验证。

## 12. 关键源码索引

- `src/ts/process/index.svelte.ts:99`（sendChat 主链）、`1591-1794`（流式生成与最终化）、`900-974`（提示构建 inlay 回注）、`1530-1545`（generationInfo 构造）、`159-210`（错误收口）
- `src/ts/process/files/inlays.ts:8-33`（InlayAsset 与独立存储）、`83-125`（图片写入）、`136-144`（签名写入）、`173-222`（读写删列）
- `src/ts/parser/parser.svelte.ts:46-119`（净化钩子）、`666-701`（inlay 占位渲染）、`713-734`（Thoughts/工具卡片）、`779-799`（净化白名单）、`900-968`（style 作用域化）
- `src/ts/process/inlayScreen.ts:7-49`（ImgGen/Emotion 标记协议）
- `src/ts/process/stableDiff.ts:64`（generateAIImage 多提供商）、`102-108`（立绘写入）
- `src/ts/process/tts.ts:80`（sayTTS）、`68-78`（播放）、`431-438`（停止）；`src/ts/process/ttsHooks.ts:29-105`（钩子管线）
- `src/ts/process/request/google.ts:722-759`（签名与内联媒体落 inlay）
- `src/ts/process/scripts.ts:99`（processScriptFull 脚本管线）、`src/ts/process/scriptings.ts:52-150`、`392-404`（脚本引擎与 generateImage）
- `src/ts/process/prereroll.ts:1-29`、`src/lib/ChatScreens/DefaultChatScreen.svelte:218-317`（reroll）
- `src/ts/plugins/apiV3/factory.ts:296`、`771-788`、`921`（iframe 沙箱）、`src/ts/plugins/plugins.svelte.ts:903-910`（v2.1 主线程执行）
- `src/ts/globalApi.svelte.ts:292`（saveDb）、`src/ts/drive/drive.ts:156-169`（同步范围）、`src/ts/process/coldstorage.svelte.ts:575`（冷存储）
- `src/lib/ChatScreens/ChatBody.svelte:249-268`（消息投影）、`Chat.svelte:129-139`（编辑）、`EmotionBox.svelte:8-13`（立绘）
- `src/lib/Playground/PlaygroundInlayExplorer.svelte:52-79`（inlay 管理）
- 测试：`src/ts/process/files/tests/inlays.test.ts`、`src/ts/process/ttsHooks.test.ts`、`src/ts/process/scriptings.test.ts`、`src/ts/parser/tests/`
