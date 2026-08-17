# Risuai 生成式输出与运行时调查笔记

> 调查对象：`E:\works\GitStudyNotes\Risuai`
>
> 调查更新日期：2026-08-17
>
> 代码快照：`0551d283faeba6e73899b01dd85ea38307b24699`（分支：`main`）
>
> 调查方式：静态代码审查；关键词 grep（inlay/iframe/sandbox/eval/Function/pyodide/lua/streaming/reroll 等）定位能力边界，通读生成主链（process/index.svelte.ts 的流式与最终化）、inlay 资产层（process/files/inlays.ts）、消息解析与净化管线（parser/parser.svelte.ts）、图像与语音产出（stableDiff.ts、tts.ts）、插件沙箱（plugins/ 与 apiV3/）、脚本引擎（scriptings.ts、pyworker.ts）及持久化入口（globalApi.svelte.ts、storage/、drive/）
>
> 调查范围：模型产出获得对象身份、专用表面、运行环境、编辑与持久化的整条链路；含 inlay 媒体资产、生成信息与重掷、图像生成协议、TTS、脚本与插件对输出的介入、持久化与回流。明确排除：对话请求类目的上下文装配与发送语义细节、消息渲染器的普通 Markdown 细节、MCP 与工具调度的执行语义、角色卡输入侧机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Risuai 与 SillyTavern 同为角色扮演聊天应用，输出模型以**消息正文文本为绝对主体（G0）**，但比 SillyTavern 多出**唯一一类获得独立对象身份的输出：inlay 资产**（G1）。inlay 是存放于独立 IndexedDB（localforage 实例 `inlay`）的媒体对象，以 UUID 寻址，类型分 image/video/audio/signature，通过 `{{inlay::id}}` 这类文本占位符嵌入消息 `data`；模型可通过 `<ImgGen="prompt">` 标记、Gemini 原生媒体返回或脚本/触发器生成它们，插件 API 可读取，提示构建时图片与签名可回注模型上下文。除此之外，SD 图片在非 inlay 模式下写入角色立绘存储（`CharEmotion`），TTS 音频仅即时播放不落对象。

**本次未找到** G2 及以上：无声明式组件协议、无模型输出进入任何执行环境（iframe 只用于插件自身 UI 与 YouTube 嵌入；Lua/Python 脚本引擎执行用户/角色维护的脚本，不属于模型输出运行面）。无 artifact 工作区、无画布、无桌面挂件；VisualNovel 模式在 `AGENTS.md` 中有目录条目，但本次快照全仓未找到对应代码。reroll（重掷）是内存级的整条消息版本替换，不持久化。

## 系统边界与总体调用链

边界：生成、渲染、后处理、媒体生成全部在浏览器前端（Svelte 5 + TypeScript）完成；Tauri 仅提供文件系统、窗口与原生 fetch 等宿主能力；Node/Hono 服务提供数据存储与 API 代理。事实源是内存 `DBState.db`（角色、聊天、设置），保存时经 `RisuSaveEncoder` 序列化为 `database.bin` 写回存储后端；inlay 二进制另存于独立 localforage 实例，与主数据库分离（详见 §8）。

**主链路（触发 -> 生成 -> 展示 -> 保存 -> 重新打开）**：

1. 发送入口 `sendChat`（`src/ts/process/index.svelte.ts:99`）构造提示。消息在进入上下文前经 `processScriptFull(..., 'editprocess')` 处理，其中角色消息里的 inlay 占位被解析：图片、音频、视频转为多模态附件，签名对象转为 signature 附件，普通 inlay 引用被剥除（`index.svelte.ts:900-974`）。
2. 请求默认走流式：逐 chunk 读取（`index.svelte.ts:1591` 起），每个批次把累积文本经输出脚本（mode 为 editoutput）处理后**整段覆盖**消息对象的 `data` 字段，并以 `reloadKeys += 1` 触发 Svelte 重渲染；另有三档性能优化模式控制刷新节流与后处理时机。
3. 流结束后收口：运行输出触发器、`runInlayScreen`（`index.svelte.ts:1775`）把 `<ImgGen>`/`{{ImgGen}}` 标记替换为占位文本、异步生成图片写入 inlay 并回填 `{{inlay::id}}`；随后运行聊天输出监听器，可选自动 TTS（`sayTTS`），并按结果 token 数决定是否自动续写。
4. 保存：内存数据库整体快照，防抖 500ms 后写入 `database.bin`（`src/ts/globalApi.svelte.ts:292`）；inlay 资产独立落 IndexedDB。
5. 重新打开：启动时从存储读回 `database.bin` 重建 `DBState.db`，消息文本含 inlay 占位；渲染时 `ParseMarkdown` 把占位替换为 blob URL 的媒体元素。inlay 引用可恢复，但资产本体不随数据库文件迁移（见 §8 边界）。

## 1. 触发方式、输出协议与对象模型

- **触发与协议**：没有结构化的"输出对象协议"。模型自由文本是唯一内容通道，宿主通过正则与标记识别以下产出意图：
  - `<ImgGen="提示词">` 与 `{{ImgGen="提示词"}}`：inlay 视图模式（imggen）下的图像生成标记，生成时先替换为 `[Generating...]`，图片落 inlay 后回填占位（`src/ts/process/inlayScreen.ts:7-49`）；
  - `<Emotion="名称">`：emotion 视图模式下的表情标记，替换为 `{{emotion::名称}}` 再经 CBS 宏解析为角色表情图；
  - Gemini 响应中的 `thoughtSignature` 与 `inlineData`：签名与内联媒体直接落 inlay（`src/ts/process/request/google.ts:722-759`）；
  - `<Thoughts>`/`<tool_call>`：展示层折叠块与工具调用卡片（`parser/parser.svelte.ts:713-734`），不产生对象。
  上述标记均以整文本正则探测，无转义或嵌套状态机；误触发的防护只有正则本身与字符转义函数（`risuEscape`/`risuUnescape`，用 Unicode 私有区字符保护 `{}()`，`parser.svelte.ts:133-150`）。
- **对象模型**：三类对象获得独立身份。
  - **消息（`Message`，`src/ts/storage/database.svelte.ts:1848`）**：`role`（user/char）、`data`（正文，含 inlay 占位）、`saying`、`chatId`（v4 UUID，发送前补齐）、`time`、`generationInfo`、`promptInfo`。事实源是内存数组 -> `database.bin`；DOM 每次由对象重渲，不是事实源。
  - **Inlay 资产（`InlayAsset`，`src/ts/process/files/inlays.ts:8-16`）**：`{data(Blob|base64), ext, name, type: 'image'|'video'|'audio'|'signature', width?, height?}`，键为 v4 UUID，存于独立 localforage 实例（`inlays.ts:30-33`）。消息通过 `{{inlay::id}}`（内联无容器）、`{{inlayed::id}}`/`{{inlayeddata::id}}`（带 `.risu-inlay-image` 容器）三种占位引用它。资产本身无来源消息、创建者或版本字段，聊天文件与资产库之间只靠文本占位的字符串匹配关联，无反向索引。
  - **生成信息（`MessageGenerationInfo`，`database.svelte.ts:1862`）**：`generationId`（即消息 chatId）、模型、输入/输出 token、上下文上限与四段阶段计时，随消息持久化，供 reroll 定位与信息展示。
- **无对象形态的产出**：TTS 音频即时解码播放（`src/ts/process/tts.ts:68-78`），不保存；非 inlay 模式的 SD 图片写入 `CharEmotion` store（角色立绘，`stableDiff.ts:102-108` 等分支），只有当前角色、无来源消息关联。

## 2. 增量生成、更新与最终化

- **更新粒度**：整段重写。流式循环把每个 chunk 的累积文本经 editoutput 脚本后直接赋给消息 `data`（`index.svelte.ts:1716-1719`），无 AST/节点 patch、无 diff。性能优化模式 `streamingDisplayOptimizationMode` 三档：off 每 chunk 全量后处理；balanced 合并 125ms 定时器 + 请求动画帧后批量刷新；strong 推迟后处理，先以纯文本渲染原始流（`renderRawStreaming`，`src/lib/ChatScreens/ChatBody.svelte:261-268`），流结束后再跑一次 editoutput（`index.svelte.ts:1738-1745`）。
- **半截流**：可选项 `removeIncompleteResponse` 用 `trimUntilPunctuation` 截断到标点（`index.svelte.ts:1708-1710`）；KaTeX 解析失败保留原文（`parser.svelte.ts:174-177`）；CSS 解析失败时按设置返回空或错误文本（`parser.svelte.ts:961-966`）。
- **最终化**：流结束（或非流式直接返回）后依次执行：输出触发器（可改写消息或要求重发，`runTrigger`，`index.svelte.ts:1763-1771`）-> `runInlayScreen`（异步图片生成并回填，`index.svelte.ts:1772-1787`）-> 聊天输出监听器（插件与自定义钩子，`runChatOutputListeners`）-> 自动 TTS（`ttsAutoSpeech`）-> 自动续写判定（token 过少或结尾非标点则递归 `sendChat(..., {continue:true})`，`index.svelte.ts:1885-1904`）。
- **失败收口**：`throwError`（`index.svelte.ts:159-210`）在开启 `inlayErrorResponse` 时把错误文本写入消息正文（`risuerror` 代码块），否则弹窗；流中止走 AbortController + reader.cancel（`index.svelte.ts:1682-1686`），中止后丢弃未完成消息但保留已写文本。

## 3. 投影表面与多视图关系

- **消息正文**：唯一主表面。`ChatBody.svelte` 对 `msgDisplay` 执行 `ParseMarkdown` 后经 `{@html}` 注入（`ChatBody.svelte:249-268`），翻译开启时投影为译后 HTML（源文本仍是消息 `data`）。
- **立绘/背景层**：`EmotionBox.svelte` 从 `CharEmotion` store 渲染角色立绘背景（`src/lib/ChatScreens/EmotionBox.svelte:8-13`），是 SD 非 inlay 输出的投影面；`BackgroundDom.svelte` 渲染 `backgroundHTML` 资产为消息底层背景。
- **Playground（开发者工具区）**：`PlaygroundInlayExplorer.svelte` 提供 inlay 资产的列表、预览与批量删除（`src/lib/Playground/PlaygroundInlayExplorer.svelte:52-79`）；另有图片生成与解析器试验页。属于本类目的唯一"对象管理器"表面。
- 无侧栏对象区、无独立窗口、无桌面挂件（Tauri 仅宿主）。同一 inlay 资产可被多条消息引用，是唯一的"一对象多投影"形式。

## 4. 表现类型、依赖与运行环境

- **支持的层级**：markdown-it（开启 html）+ highlight.js 按语言动态加载高亮 + KaTeX 数学（`$$...$$`）+ DOMPurify 净化；模型产出媒体经 inlay 占位渲染为 `img`/`video controls`/`audio controls`（`parser.svelte.ts:681-696`）。
- **净化边界**（`parser.svelte.ts:46-119` 的 DOMPurify 钩子 + `trimMarkdown` 白名单）：
  - iframe 仅放行 `https://www.youtube.com/embed/` 前缀的 src，其余直接移除（`parser.svelte.ts:46-52`）；
  - class 一律加 `x-risu-` 前缀（`hljs`、`x-risu-` 开头保留）；href 只允许 http(s) 并强制 `target=_blank`；
  - `<style>` 块先 hex 编码再经 CSS AST 解析：选择器加 `x-risu-` 前缀并作用域到 `.chattext`，`@import` 仅接受空 data URI（`encodeStyle`/`decodeStyle`，`parser.svelte.ts:900-968`）；
  - `hideAllImages` 时隐藏外部图片与 background-image；保留下标/数学相关的 MathML 标签集（`trimMarkdown`，`parser.svelte.ts:779-799`）。
- **运行环境**：模型输出无执行面。全仓 `eval`/`new Function` 仅出现在插件系统（见 §7）。iframe 在本快照中的用途只有插件容器与 YouTube 嵌入；无 WebView、无 worker 承载模型产出。Pyodide（`src/ts/process/pyworker.ts`）与 wasmoon Lua 引擎只运行脚本系统代码（输入侧，用户/角色维护）。
- 本次未找到 Mermaid/图表渲染、Canvas 输出、HTML 小应用或可下载代码项目等层级（全仓 grep 无对应渲染管线）。

## 5. 用户交互、事件与错误反馈

- **消息级操作**（宿主固定按钮，非模型声明）：复制（解析后 HTML 或源文本）、编辑、删除、翻译、TTS 播放、reroll 前进/后退（`src/lib/ChatScreens/Chat.svelte:743-763`、`796-809`）。`PartialEditController.svelte` 提供块级与拖选式局部编辑/删除，保存时整段回写消息 `data`（`Chat.svelte:133-139`）。
- **事件回传**：插件经 `addRisuChatListener('output', ...)` 观察输出（`src/ts/plugins/apiV3/v3.svelte.ts:730-733`）；自定义脚本（Lua）经 `runLuaEditTrigger` 在四种模式下改写文本；TTS 前后处理钩子由插件注册（`registerTTSPreprocessor`/`registerTTSPostprocessor`，`src/ts/process/ttsHooks.ts:29-48`），可替换音频、改 mime 或跳过播放（含超时与容错，`ttsHooks.ts:61-105`）。
- **错误反馈**：生成/图片/TTS 错误以 toast 与消息内 `risuerror` 代码块呈现；`<tool_call>` 渲染为消息内卡片。
- 流式性能模式 `strong` 下的 `renderRawStreaming` 属源码确认的入口，实际视觉效果未运行验证。

## 6. 编辑、diff、版本与协作

- **编辑**：全文覆盖式。编辑保存直接覆写消息 `data`（`Chat.svelte:129-131`）；局部编辑同样整段覆盖。编辑后 inlay 占位符保留与否取决于用户操作，系统不校验引用完整性。
- **版本**：reroll 是唯一版本机制，且为**内存级**：生成时按 chunk 累积各候选文本（`addRerolls`，`src/ts/process/prereroll.ts:26-29`），reroll 时以 `safeStructuredClone` 快照整段消息数组替换（`DefaultChatScreen.svelte:218-317`），不落盘，刷新即失。无 diff、无 patch、无接受/拒绝、无分支。
- **协作**：单用户本地应用，无协作；云同步（drive）只同步主数据库与 assets（见 §8），对象级冲突处理不存在。

## 7. 能力桥、执行位置与权限范围

- **执行位置**：模型输出只在宿主 DOM 渲染，无脚本执行。插件系统分两代：
  - API 3.0：隐藏 iframe + postMessage 桥，sandbox 允许 `allow-scripts`、`allow-modals`、`allow-downloads`，带 CSP；插件代码在 iframe 内经 `eval('(async () => ...)')` 运行（`src/ts/plugins/apiV3/factory.ts:296`、`771-788`、`921`）。iframe 默认隐藏，可 `showContainer` 放大为全屏 UI（`v3.svelte.ts:916-941`）。
  - API 2.1：主线程 `new Function` 执行，先经 `checkCodeSafety` 静态改写（`src/ts/plugins/plugins.svelte.ts:903-910`）。
  插件 iframe **承载插件自身 UI 与代码，不承载模型输出**；模型文本不会注入 iframe 执行。
- **能力桥**：插件 API 可读取 inlay（`readInlay`，`v3.svelte.ts:739-741`）、读写数据库、网络请求、注册输出监听器与 replacer；脚本引擎（Lua/Python）可调用 `generateImage` 生成图片并写入 inlay（`src/ts/process/scriptings.ts:392-404`），触发脚本有 `runImgGen` 效果（`src/ts/process/triggers.ts:1539-1557`）——这些桥接由脚本作者（用户/角色）预编译，模型本身只能通过文本标记间接驱动。无逐项授权/审批 UI；权限按插件名在安装/运行期确认（`getPluginPermission`）。
- 模型输出侧无网络、存储或宿主动作能力声明：媒体引用全部解析为已存在资产，外部图片地址不加载执行（仅 img 标签可显示，且受 `hideAllImages` 控制）。

## 8. 持久化、恢复、分享与导出

- **主库**：`DBState.db` -> `RisuSaveEncoder` -> `database.bin`（500ms 防抖、多备份轮换，`globalApi.svelte.ts:292-525`）；后端抽象覆盖 Tauri FS、LocalForage、Node 服务、账户存储。消息的 `data`（含 inlay 占位）、`generationInfo`、`promptInfo` 全部随主库往返。
- **inlay 资产库**：独立 localforage 实例（IndexedDB 库名 `inlay`），与主库分离。恢复消息时占位符可解析，但资产不随 `database.bin` 备份/迁移，也不在 drive 同步范围内（`src/ts/drive/drive.ts:156-169` 只枚举主存储 keys）。冷存储归档旧聊天时同样只归档消息文本（`src/ts/process/coldstorage.svelte.ts:529`），inlay 二进制不在归档 payload 中（`coldstorageData.ts` 仅替换资源路径）。跨设备/重装后 inlay 媒体会丢失而占位保留——此为静态推断，未运行验证。
- **分享/导出**：角色卡导出/导入（.risum/.risup/.charx）不含 inlay 资产；正则脚本可导出单文件 JSON（`scripts.ts:30-39`）。聊天导出入口本次未找到（Playground 或数据管理面未逐一核对）。删除 inlay 的唯一常规入口是 PlaygroundInlayExplorer（逐项/批量），无按引用清理或孤儿回收。

## 9. 模型回流、对象感知与持续维护

- **提示构建时的 inlay 解析**（`index.svelte.ts:900-974`）：角色消息中 `{{inlayeddata::id}}` 按资产类型回注——图片转为 multimodal 附件（模型支持图像输入时）或经本地图像描述模型生成文字附注；video/audio 转为多模态附件；signature 转为 signature 附件（Gemini 签名校验链）。`{{inlay::}}`/`{{inlayed::}}` 在角色消息中被剥除，而用户消息中的 inlay 引用会解析为多模态附件。
- **持续维护的对象**：无。模型不能查询 inlay 列表或定向修改某个资产；下一轮上下文里图片以 base64 附件或描述文本形式重新出现，但模型无从得知其 UUID 或"同一个对象"概念。reroll 候选不回流。记忆系统（Hypa/Supa 等）属输入侧维护的摘要文本，不面向输出对象。
- **结论**：对象感知仅存在于"宿主程序在提示侧代取内容"这一层，模型本身无寻址能力；不属于 G5 意义上的环境化活对象。

## 10. 生命周期、资源治理与性能

- **inlay 资产**：无引用计数、无自动回收、无孤儿清理；blob URL 在渲染侧缓存（`blobUrlCache`，`parser.svelte.ts:664-680`），生命周期为页面会话，未找到 revoke 逻辑（Playground 手动删除时单独 revoke）。
- **TTS**：模块级单例 `sourceNode` 持有当前播放源，`stopTTS()` 停止（`tts.ts:431-438`）；AudioContext 每次播放新建，未找到统一关闭/计数。
- **脚本引擎**：Lua 引擎与 Pyodide 上下文按 mode 复用，代码变更时重建旧实例并 `close()`（`scriptings.ts:84-104`）；脚本请求有每分钟限额（`scriptings.ts:336` 附近）。
- **生成侧**：流式刷新按性能模式节流（125ms + rAF，`index.svelte.ts:1628-1681`）；中止走 AbortController；自动续写与输出触发器重发共享同一 abortSignal，可能形成较长链但无显式递归上限（`resendChat`/autoContinue 均递归 `sendChat`）。
- 不可见消息不冻结（静态 HTML），无对象级暂停/冻结策略；长会话限额集中在输入侧（上下文 token 预算、脚本请求限额）。

## 11. 测试、已确认边界与未验证事项

- **测试现状**：vitest（`pnpm test`）。覆盖 inlay 存储 CRUD 与迁移（`src/ts/process/files/tests/inlays.test.ts`）、TTS 钩子管线（`ttsHooks.test.ts`）、脚本系统（`scriptings.test.ts`）、解析器（chatML、chatVar、CBS 条件/转义/循环，`src/ts/parser/tests/`）、冷存储数据、翻译正则（`edittransRegex.test.ts`）等。**本次未找到**针对流式管线、提示构建 inlay 回注、净化/渲染链路、reroll 交互的测试；无 E2E。类型检查为 `pnpm check`（svelte-check）。测试均未运行。
- **已确认边界**（源码直接确认）：
  - 模型输出无执行面：`eval`/`new Function` 命中全部位于插件系统（v2.1 主线程、v3 iframe 内），且执行的是插件代码；iframe 仅插件容器与 YouTube 嵌入（`parser.svelte.ts:46-52`）。
  - 无 artifact/画布/工作区/桌面输出表面；`Canvas` 仅用于 inlay 图片缩放与压缩（`inlays.ts:83-125`）。
  - VisualNovel 模式：`AGENTS.md` 目录结构条目声称存在 `src/lib/VisualNovel/`，但本次快照在 `src` 全目录 glob 与内容搜索（VisualNovel/visual novel 等大小写变体）均无命中，仅有 `src/ts/iris.ts:86` 提示词文本中的 "visual novel style" 字样；按当前快照判定该能力不存在。
  - reroll 为内存级版本替换，不持久化。
  - inlay 资产不随 `database.bin`、drive 同步与冷存储迁移。
- **推断**（静态代码）：inlay 跨设备丢失行为、流式性能模式的实际渲染效果、插件 iframe 桥的完整可用性、自动续写链在长会话中的行为均为推断。
- **未验证事项**：未运行应用与测试；所有 DOM 行为（消息气泡、立绘、Playground 列表、iframe UI、TTS 播放）与浏览器端 IndexedDB 行为未经运行验证。

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
- `src/ts/globalApi.svelte.ts:292`（saveDb）、`src/ts/drive/drive.ts:156-169`（同步范围）、`src/ts/process/coldstorage.svelte.ts:529`（冷存储）
- `src/lib/ChatScreens/ChatBody.svelte:249-268`（消息投影）、`Chat.svelte:129-139`（编辑）、`EmotionBox.svelte:8-13`（立绘）
- `src/lib/Playground/PlaygroundInlayExplorer.svelte:52-79`（inlay 管理）
- 测试：`src/ts/process/files/tests/inlays.test.ts`、`src/ts/process/ttsHooks.test.ts`、`src/ts/process/scriptings.test.ts`、`src/ts/parser/tests/`
