# Risuai 消息渲染调查笔记

> 调查对象：`https://github.com/kwaroran/Risuai`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`e565563a288ebe4c65b6099a1645ba477d1c84b4`（分支：`main`）
>
> 调查方式：只读源码梳理；对 `src/ts/parser/`、`src/ts/process/index.svelte.ts`、`src/lib/ChatScreens/` 逐文件阅读，并用全文检索交叉验证调用点；未安装依赖、未运行应用
>
> 调查范围：消息数据模型、流式链路、列表窗口化、消息壳层、Markdown 管线、结构化内容（资产 inlay、表情、工具）、HTML/CSS 承载边界、交互反馈、性能策略与扩展机制；明确排除：持久化 schema 与分支数据语义、Composer 与发送控制、导出功能、插件 API 全貌
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Risuai 以纯字符串消息模型驱动渲染：`Message` 只有 `data` 字符串加角色等元数据，正文渲染是一条「变量解析 → 资产替换 → 正则脚本 → Markdown → 高亮 → DOMPurify」的字符串管线，没有结构化 part 或 AST 层。UI 采用 Svelte 5 响应式加命令式 DOM 混合：`Chats.svelte` 用非加密哈希做消息实例的差量挂载/卸载，流式期间对最后一条消息直接调用已挂载实例的更新方法，避免整段重挂载。

流式消费端有三档优化模式（`off` / `balanced` / `strong`）：默认逐 chunk 全量处理；balanced 把 chunk 累积后以 125ms 定时器加 rAF 合帧，每次合帧对累计全文运行 `editoutput` 正则脚本并重新解析；strong 在流式期间完全不运行脚本、直接显示原文，收尾时一次性补跑脚本。无论哪档，可见帧都是「累计全文重新走 Markdown 管线」而非增量更新。

代码中可以确认以下实现特点：

- 列表窗口化：默认只挂载最近 30 条，滚到顶部每次追加 15 条，消息按哈希差量挂载/卸载（`src/ts/chatLoadPages.ts:1-2`、`src/lib/ChatScreens/Chats.svelte:65-167`）。
- 富文本能力集中在字符串协议上：`{{img::}}` 类资产占位符、`{{inlay::}}` 图片嵌入、`<Thoughts>`/`<tool_call>` 正文标记、KaTeX、按需加载的 highlight.js，以及可作用域化的消息内 `<style>`。
- 特色能力：角色表情图系统（`CharEmotion` + waifu 主题的 `TransitionImage`）、Stable Diffusion 图生成 inlay（`<ImgGen="...">`）、可定制的 HTML 消息壳主题（`guiHTML`）、消息级 Lua 触发器按钮。
- 承载边界：DOMPurify 清洗（class 统一加 `x-risu-` 前缀、iframe 只放行 YouTube embed、href 只放行 http(s)）；消息 CSS 用 `.chattext` 选择器前缀做作用域；插件运行在无 same-origin 的沙箱 iframe 中并带独立 CSP。
- 主文档没有启用 CSP（`index.html` 中 CSP meta 处于注释状态）。

## 总体渲染链路

```text
Message.data（字符串）
  -> Chat.svelte  displaya(): risuChatParser()      变量/脚本/CBS 块解析
  -> ChatBody.svelte  markParsing(): ParseMarkdown()
       parseAdditionalAssets   {{img::}} 等资产 -> 文件 src
       processScriptFull(editdisplay)   Lua trigger + 插件 hook + 正则脚本
       parseInlayAssets        {{inlay::}} -> blob URL
       parseThoughtsAndTools   <Thoughts> -> details；<tool_call> -> 提示行
       encodeStyle             <style> hex 编码为 <risu-style>
       renderHighlightableMarkdown
            $$ -> KaTeX
            markdown-it (html: true) -> HTML
            hljs 占位符替换（按需语言加载）
  -> trimMarkdown(): DOMPurify.sanitize + decodeStyle（CSS 作用域改写，二次清洗）
  -> addMetadataToElement()（当前恒为空操作，见第 7 节）
  -> ChatBody 模板 {@html ...} 输出
```

流式链路：

```text
请求层 ReadableStream reader（process/index.svelte.ts:1591-1753）
  -> 每 chunk 更新 lastResponseChunk
  -> off：立即 processScriptFull(editoutput) 写 message.data
     balanced/strong：pendingStreamingResult + 125ms 定时器 + rAF
        -> flush：balanced 先 editoutput 后写 data；strong 直接写 data（跳过脚本）
  -> message.data 赋值 + character.reloadKeys++
  -> Chats.svelte $effect 重跑 -> updateChatBody()
  -> 流式消息哈希不含 data -> 命中既有实例 -> updateStreamingDisplay(rawStreamingText)
  -> Chat.svelte 重新 risuChatParser -> ChatBody 重新 ParseMarkdown（strong 直接原样文本）
  -> 收尾：isStreaming=false -> 哈希含最终 data -> 整条重挂载完整渲染
```

## 1. 消息与内容块数据模型

渲染器的输入是 `Message`（`src/ts/storage/database.svelte.ts:1848-1860`），字段契约如下：

| 字段 | 渲染用途 |
|---|---|
| `role` | 只有 `'user'` 与 `'char'` 两值，决定壳层布局与图标 |
| `data` | 唯一正文来源，纯字符串 |
| `chatId` / `time` | 消息身份与时间戳（哈希窗口与书签依赖 chatId） |
| `generationInfo` / `promptInfo` | 模型信息展示、reroll 与提示详情 |
| `disabled` | 渲染分隔线并表达 `'allBefore'` 截断语义 |
| `isComment` | 评论消息（分支跳转链接） |
| `saying` | 群聊中发言成员 id，用于渲染名 |

没有系统、工具或 reasoning 角色：这些内容都作为字符串标记出现在 `data` 里，由解析阶段识别。

渲染上下文由组件参数传递：`Chat` 接收 `message`、`role`、`idx`、`character`（`createSimpleCharacter` 裁剪出的简单角色，只带脚本与资产）、`firstMessage`、`isComment` 与 `messageGenerationInfo`。`risuChatParser` 的 `CbsConditions`（`firstmsg`、`chatRole`）让变量与脚本按消息角色和首条身份生效。

## 2. 流式数据到 UI 的更新链

流式消费端位于 `src/ts/process/index.svelte.ts:1591-1753` 的 `sendChat` 内：请求层返回 ReadableStream，循环 `reader.read()` 逐 chunk 更新累计结果。`StreamingDisplayOptimizationMode`（`off`/`balanced`/`strong`，`database.svelte.ts:28`）在生成开始时写入会话，生成结束后清除。

三个档位的差异集中在「多久处理一次」与「流式期间跑不跑正则脚本」：

| 档位 | chunk 缓冲 | 每次 flush 的正文处理 | 界面显示 |
|---|---|---|---|
| off | 无 | 每 chunk 立即 `editoutput` 脚本 + 全量 Markdown | 全量渲染 |
| balanced | 125ms 定时器 + rAF 合帧（`scheduleStreamingDisplayFlush`，`index.svelte.ts:1667-1681`） | 累计全文 `editoutput` + 全量 Markdown | 全量渲染 |
| strong | 同上 | 流式期间跳过 `editoutput`，仅 trim 后直接写入 | `rawStreamingText` 原样文本（`whitespace-pre-wrap`，`ChatBody.svelte:262`），不做任何 Markdown |

合帧器是串行的：`flushStreamingDisplay` 用 `streamingFlushPromise` 保证同一时刻只有一个处理中，期间新到达的 chunk 置 `streamingFlushQueued`，处理完再取最新值，丢弃中间帧。`off` 模式下无合帧，每个 chunk 都同步跑 `processScriptFull(...,'editoutput',...)`，其结果直接写 `message[msgIndex].data`。`removeIncompleteResponse` 开启时会在写入前用 `trimUntilPunctuation` 截到最后一个标点。

每次写入后递增 `character.reloadKeys`，配合对 `DBState` 深层状态对象的赋值，这是向 UI 传递变化的通知点（该失效在 Svelte 5 代理中的确切传播语义未运行验证，见文末）。

`Chats.svelte` 的 `$effect`（`Chats.svelte:200-227`）重跑 `updateChatBody`：对最后一条 char 消息，若会话仍在流式且优化模式非 off，哈希计算排除 `message.data`（`Chats.svelte:99`），因此 chunk 更新不改变哈希，已挂载实例命中，直接调用其实例方法 `updateStreamingDisplay` 传入最新 `rawStreamingText`。`Chat.svelte` 随即在 `$effect.pre` 中重新执行 `risuChatParser`，`ChatBody` 的 `markParsing` 重新走完整 `ParseMarkdown`。

收尾阶段（`index.svelte.ts:1727-1753`）：先强制 flush 剩余内容；strong 模式此时补跑一次 `editoutput`；随后 `isStreaming=false` 并清除优化模式。哈希随即纳入最终 `data`，与流式期间的哈希不同，整条消息被卸载并重新挂载，以完整管线渲染最终文本——因此"strong 流式期间看到的是未处理原文"只影响流式过程，不影响最终显示。完成后还依次执行 `runInlayScreen`（处理 `<Emotion>`/`<ImgGen>` 替换）、`runChatOutputListeners`（插件 `chatOutput` 钩子）与可选的自动 TTS。

## 3. 消息列表、窗口化与滚动

`DefaultChatScreen.svelte:47` 维护 `loadPages` 状态，初值来自 `getInitialChatLoadPages`（默认 30，`chatLoadPages.ts:1-18`，可由数据库字段 `chatLoadInitialPages` 覆盖）。滚动容器是 `flex-col-reverse` 的纵向滚动 div（`DefaultChatScreen.svelte:572-585`）：滚到顶部 100px 内且消息数大于当前窗口时，`loadPages += getAdditionalChatLoadPages`（默认 15）。

`Chats.svelte` 是窗口化的执行者，它不用 `{#each}` 而是命令式挂载：

1. 对 `[length-loadPages, length)` 范围内的每条消息计算 32 位哈希（`hashCode`，输入为 data、chatId、idx、头像尺寸、disabled、reloadPointer）。
2. 与上一轮的哈希集合比较：新哈希 → `mount(Chat, {target: div})` 并插到前一个已挂载节点之后；既有哈希 → 调用实例的 `updateStreamingDisplay`（仅流式场景有意义）。
3. 集合差集 → `unmount` 并移除 DOM（`Chats.svelte:152-163`）。

滚动锚定依赖两条事实：新消息始终 prepend 到最旧消息之前（视觉底部），加载更早历史时新节点插在既有节点之后（视口上方），因此滚动位置天然保持；用户不在底部且 `autoScrollToNewMessage` 开启时，新消息不自动滚动，而是显示"新消息"按钮（`showNewMessageButton`，滚动到底部后消失）。书签/跳转到指定消息时，先临时把 `loadPages` 扩到目标索引覆盖的范围，再轮询 `[data-chat-index]` 元素并 `scrollIntoView`（`DefaultChatScreen.svelte:73-135`）；截图功能则把 `loadPages` 设为 `Infinity` 后逐条 canvas 拼接（同文件 `screenShot`，`DefaultChatScreen.svelte:449-503`）。

## 4. 消息壳层与角色分派

消息壳只有一个组件：`Chat.svelte`（1157 行），同时承载用户、角色、评论、首条问候与群聊消息，通过 props（`role`、`isComment`、`idx === -1`、`firstMessage`）分派。`src/lib/ChatScreens/Message.svelte` 是标注"future-proofing 重写"的 27 行 TODO 存根，未被引用。

壳层渲染按主题分四路（`Chat.svelte:1068-1147`）：

- `mobilechat`：气泡式，头像在角色侧，用户消息右对齐。
- `cardboard`：卡片式，大头像 + 名称 + 固定高度正文区。
- `customHTML`：使用 `DBState.db.guiHTML` 字符串作为消息壳模板，经 `RenderGUIHtml`（DOMParser 解析）后由 `renderGuiHtmlPart` 递归转译成 Svelte 组件（`Chat.svelte:220-229, 918-1056`）。模板只接受约二十种白名单标签，未知标签降级为 `div`；四个特殊标签 `RISUTEXTBOX`、`RISUICON`、`RISUBUTTONS`、`RISUGENINFO` 分别被替换为正文框、发送者头像、操作栏和生成信息，`A` 标签的 href 只放行 `https`。
- 默认：头像 + 名称行 + 操作栏 + `genInfo`（模型信息、LLM 翻译状态）+ 正文。

正文容器是带 `chattext` class 的 span（`Chat.svelte:425`），用 `{#key}` 包住 `ChatBody`，键值叠加 `ReloadChatPointer[idx]`（触发器、角色切换等场景自增），指针变化时整块重挂载。首条消息（`idx === -1`）由 `DefaultChatScreen` 直接渲染一个独立 `Chat`，支持 alternateGreetings 分页和 `{{none}}`/`{{blank}}`/空串占位（显示"无消息"文案）；评论消息以 `{{specialcomment::branchedfrom::...}}` 数据渲染分支跳转链接。操作栏（`iconButtons`）包含复制、翻译、编辑、TTS、删除、书签、分支、禁用、禁用以上与 reroll，桌面端主要按钮直接展示、次要按钮收进 PopupButton。

## 5. Markdown、代码与富文本管线

`ParseMarkdown`（`src/ts/parser/parser.svelte.ts:736-777`）是正文管线的总入口，处理顺序本身是渲染协议：

1. `parseAdditionalAssets`：替换 `{{img::名称}}` 类资产占位符（raw/path/img/video/audio/bgm/bg/emotion/asset 等十余种类型，正则见 `assetRegex`，`parser.svelte.ts:408`）。资产名按角色 `additionalAssets` 精确匹配；未命中且 `legacyMediaFindings` 关闭时做 Levenshtein 模糊匹配（`getClosestMatch`，距离上限 `assetMaxDifference`）；同一资产多条路径时用 `pickHashRand` 按会话确定性随机选一条。多选项时在脚本处理后二次解析，覆盖脚本改写出的新占位符。
2. `processScriptFull(char, data, 'editdisplay', ...)`：依次运行 Lua editDisplay 触发器（`runLuaEditTrigger`）、插件 `pluginV2.editdisplay` 钩子、全局+角色+模块正则脚本（`scripts.ts:99-387`）。
3. `parseInlayAssets`：把 `{{inlay::id}}`/`{{inlayed::id}}`/`{{inlayeddata::id}}` 换成本地 blob URL 的图片/视频/音频标签（parser.svelte.ts:666-701）。
4. `parseThoughtsAndTools`：深度配对的 `<Thoughts>` 折叠为 `<details><summary>`；`<tool_call>id\uf100名称</tool_call>` 替换为一行 `x-risu-tool-call` 提示（parser.svelte.ts:713-734）。
5. `encodeStyle`：`<style>` 内容 hex 编码成 `<risu-style>` 保护起来，防止 DOMPurify 直接处理。
6. `renderHighlightableMarkdown`：`$$...$$` 先被 `katex.renderToString` 替换（`renderMarkdown`，parser.svelte.ts:152-204，`output: 'mathml'`、`displayMode: false`），随后 markdown-it 渲染（`html: true`、`breaks`、`typographer`、引号占位符机制）；带语言标记的代码围栏由第二个 markdown-it 实例（`mdHighlight`）输出 `pre-hljs-placeholder` 占位，之后逐块按需 `import` highlight.js 语言并生成 `pre.hljs`（switch 共映射 18 种语言，未知语言转义为纯文本，`risuerror` 输出错误面板）。
7. `trimMarkdown`（ChatBody 渲染时）：普通内容直接经 DOMPurify 清洗；含 `risu-style` 时先取得清洗后的 DOM，再只解码其中真实的样式节点并原地替换为 style。CSS 不再作为 HTML 字符串重新交给 DOMPurify，因而其中含有类似标记的文本或 SVG data URL 时不会被清洗器误删（`parser.svelte.ts:779-834,966-1003`）。

两个 markdown-it 实例都 `disable(['code'])`（缩进代码块规则），正文行内代码与围栏行为由上述占位机制统一处理。引号处理值得一提：markdown-it 的 typographer 把引号替换为 PUA 字符，随后按 `customQuotes`/`blockquoteStyling` 设置决定是原样还原还是包成 `<mark risu-mark>` 引用样式。

`risuChatParser`（parser.svelte.ts:1538-1812）是变量层，按语法元素划分能力：

- 变量与函数调用：`{{变量}}`、`{{函数::参数}}`（经 `registerCBS` 注册到 `matcherMap`，如 `{{file::}}` 在显示模式输出文件名块）、`{{call::}}` 复用已定义函数，`?:` 前缀表示计算表达式。
- 控制块：`{{#if}}`/`{{#when}}`（含 not/and/or/is/var/toggle/比较等条件）、`{{#each}}`、`{{#func}}`、`{{#escape}}`、`{{#pure}}` 与 `{{#code}}` 归一化，块嵌套有 512 层数组与 20 层调用栈上限。
- 兼容归一：`<(user|char|bot)>` 与 `{{user}}`/`{{char}}` 占位在解析前统一替换。

Chat 的 `displaya` 以 `visualize: true` 调用它，使 `{{file::}}` 这类函数走显示分支。

## 6. 工具、reasoning、附件与自定义节点

- 工具调用：请求层把 API 工具调用序列化为 `<tool_call>{id}\uf100{name}</tool_call>` 文本（`src/ts/process/mcp/mcp.ts:359`），展示层替换为一行只读提示（带 🛠️ 图标与 `x-risu-tool-call` class），没有工具卡、审批或展开交互；工具参数与结果都在上下文侧处理，不进入消息正文。
- reasoning：`<Thoughts>` 标签折叠为可展开的 details（默认文案来自语言文件 `cot`），不区分流式状态。
- 资产 inlay：`{{inlay::id}}` 系列引用 localforage 的 inlay 库（`src/ts/process/files/inlays.ts:30-33`），图片上传时经 canvas 缩放到不超过 1024×1024，读取时迁移为 Blob 并缓存 object URL（`blobUrlCache`）。发送输入框粘贴图片、菜单"发布文件"都走 `postChatFile` → inlay id 写入消息文本；多模态模型把 inlay 图片作为 `{{inlayed::}}` 拼接进提示（`inlays.ts:225-228` 的 `supportsInlayImage` 判定）。
- 表情图：`{{emotion::名称}}` 按角色 `emotionImages` 列表解析为图片；正则脚本 `@@emo 名称` 把表情压入全局 `CharEmotion` store（`scripts.ts:184-206`），waifu/waifuMobile 主题的 `ChatScreen` 据此驱动右侧 `TransitionImage`（切换时新旧两张图交叉淡入淡出，多表情支持横向分格，`emp` 样式叠加显示），桌面聊天面板可用 `ResizeBox` 拖动调整大小。
- 屏幕模式：角色 `viewScreen` 为 `emotion` 时模型按指令输出 `<Emotion="...">` 命令，`runInlayScreen` 把它转成 `{{emotion::}}`；为 `imggen` 时 `<ImgGen="...">` 先显示 "[Generating...]" 占位，异步调 Stable Diffusion 生成后把图片写入 inlay 库并替换为 `{{inlay::id}}`（`src/ts/process/inlayScreen.ts:7-50`）。
- 文件：`{{file::名称::base64}}` 在显示模式下输出带 `risu-file` class 的文件名块（`cbs.ts:972-981`），上下文侧才解码内容。
- 音频：`{{bgm::}}` 输出隐藏的 `risu-ctrl="bgm___auto___路径"` 元素，由 `observer.svelte.ts` 的 MutationObserver 轮询接管播放。

## 7. HTML、CSS 与内容承载边界

正文 HTML 最终通过 `{@html}` 输出，但任何路径都先经 `trimMarkdown`（`parser.svelte.ts:779-799`）调用 DOMPurify；该函数同时是历史、流式、翻译后的统一清洗点，渲染组件里没有绕过它的输出路径。`ChatBody` 渲染时还会调用 `addMetadataToElement` 把模型名编码成零宽字符注入 `<p>` 标签（`parser.svelte.ts:860-874`），但开关函数 `aiWatermarkingLawApplies` 当前恒返回 false（`globalApi.svelte.ts:2333-2338`），该路径在本快照中是死代码。

DOMPurify 通过全局 hook 收紧三类行为（parser.svelte.ts:46-119）：

- `uponSanitizeElement`：iframe 只放行 `https://www.youtube.com/embed/` 前缀；img 在 `hideAllImages` 开启时替换为 `/none.webp` 占位（含 style 里 background-image 的清理），否则补 `loading="lazy"`/`decoding="async"`。
- `uponSanitizeAttribute`：class 逐个加 `x-risu-` 前缀（`hljs`、`x-risu-` 开头的例外）；href 只允许 `http://`/`https://` 并加 `target="_blank"`，其余置空；`IMG/SOURCE/VIDEO/AUDIO/STYLE` 的 `blob:` src 通过 `forceKeepAttr` 保留（inlay 依赖）。
- `ADD_TAGS`/`ADD_ATTR` 白名单：style、risu-style、iframe、MathML 系列（KaTeX 的 annotation/semantics/mrow 等），以及 risu-ctrl/risu-btn/risu-trigger/risu-mark/risu-id/x-hl-lang/x-hl-text 等自定义属性。

消息内 `<style>` 走特殊路径（parser.svelte.ts:930-1003）：内容先以 hex 编码躲过 HTML 清洗，随后由 `decodeStyleContent` 用 `@adobe/css-tools` 解析 CSS，选择器加 `.chattext ` 前缀、class 加 `x-risu-` 前缀，再把所得 CSS 放进已清洗 DOM 的真实 style 节点。这与 SillyTavern 的 custom-style 思路同类：样式留在主文档，隔离靠选择器前缀而非 Shadow DOM。解析失败时按 `returnCSSError` 设置回显错误文本或丢弃；`@import` 规则只有 data: 开头才被保留，且被清空为 `data:,`。为避免样式标签提早闭合，恢复前会转义 CSS 内的 `</style` 序列。

主文档 `index.html` 的 CSP meta 处于注释状态（index.html:14），页面级 CSP 未启用。插件运行在独立沙箱 iframe（`src/ts/plugins/apiV3/factory.ts:438, 784-788, 894-921`）：sandbox 仅 `allow-scripts allow-modals allow-downloads`（无 `allow-same-origin`，保持 opaque origin），srcdoc 附带 CSP，插件与主文档通过 postMessage RPC 桥通信（`SandboxHost`）。该沙箱服务于插件 UI，不参与普通消息正文的渲染路径。iframe 内 CSP 指令如下：

- 网络与容器受限：`connect-src 'none'`、`frame-src 'none'`、`object-src 'none'`、`base-uri 'none'`。
- 脚本只认 nonce：`script-src 'nonce-*' 'wasm-unsafe-eval'`，插件代码以内联脚本注入 srcdoc 并带随机 nonce。
- 媒体类资源放宽：`img-src * data: blob:`、`font-src * data: blob:`、`media-src * data: blob:`、`style-src * 'unsafe-inline'`。

## 8. 内容交互反馈

- 复制：`Chat.svelte:511-741` 支持富文本复制——重新 `ParseMarkdown` 后用 DOMParser 拆 DOM，把引用/段落/强调按主题变量内联成样式，图片经 fetch + canvas 重编码为 data URL，再以 `ClipboardItem` 同时写 `text/plain` 与 `text/html`；成功弹 `alertNormal(language.copied)`，异常降级为 `writeText` 纯文本并显示行内状态。代码块复制走右键菜单（`observer.svelte.ts:10-54`：复制全文 / 按 `x-hl-lang` 扩展名下载文件）。
- 编辑：整段编辑切换 textarea；块级编辑（`PartialEditController.svelte`）在悬停块上追加编辑/删除按钮，拖选文本也可直接编辑；保存时把选中 HTML 转纯文本，经 `findAllOriginalRangesFromText` 的 exact/anchor/fuzzy/bigram 四级匹配定位原文区间（`src/ts/parser/partialEdit.ts:326-619`），`replaceRange` 替换后回写 `message.data` 并重新渲染，匹配失败弹窗提示。
- 消息内按钮：`[risu-btn]`/`[risu-trigger]` 元素点击后运行 `runLuaButtonTrigger` 或手动触发器，结果可整体替换会话并自增 `ReloadChatPointer` 重渲染（`Chat.svelte:231-271`）。
- 翻译：按钮切换已翻译/原文，LLM 翻译有加载旋转占位与"重新翻译/编辑翻译"入口（`ChatBody.svelte:109-149`）；翻译可在 HTML 格式化前或后进行，后者的路径会重新执行代码高亮（`postTranslationParse`）。
- 状态反馈：删除确认、书签命名弹窗、TTS 按钮、分支创建，均通过既有 alert 系统；`clickToEdit` 设置下单击正文直接进入编辑模式。

## 9. 性能、缓存与测试

性能策略分四层：

- 列表层：窗口化（默认 30+15）限制常驻消息实例数；哈希差量挂载避免整表重渲染；流式消息在哈希中排除 data，使合帧更新只走实例方法而不是重挂载。
- 流式层：125ms + rAF 合帧丢弃中间帧；strong 模式流式期间跳过 `editoutput` 脚本与全部 Markdown 解析，只显示纯文本。
- 解析层：`processScriptCache`（键为脚本+数据+模式的哈希，容量上限 1000，`scripts.ts:68-93`）、`fileSrcCache` 与 `blobUrlCache`、资产索引缓存（`assetsCache`，角色切换时重建）；highlight.js 语言按需 `import`，只加载实际出现的语言；`ChatBody` 组件内缓存上一次解析结果（`lastParsed`），翻译/角色参数未变时复用。
- 渲染层：hljs 高亮结果直接进入清洗后的 HTML，不在 DOM 上二次高亮；`{#key}` 控制 ChatBody 重挂载时机。

可确认的取舍是：每次流式合帧仍然对累计全文执行完整 Markdown 管线（含正则脚本、KaTeX、高亮与清洗），成本随单条回复线性增长；`balanced` 与 `off` 的唯一区别是合帧频率，不是重算范围。

测试：仓库使用 vitest（`package.json` 的 `test` 脚本），共 24 个 `*.test.ts` 文件。覆盖渲染相关的主要有：parser 的 CBS 函数（strings/loop/escapes/conditionals）、chatML、chatVar、inlay 资产读写、chatLoadPages 数值归一化、scriptings 触发器；另有 GUI 原语、请求层、翻译正则等测试。未发现针对 `Chat`/`ChatBody`/`Chats` 组件或流式合帧链路的组件级测试，`parser.svelte.ts` 的 DOMPurify hook 与 `decodeStyle` 没有直接测试文件。

## 10. 扩展方式与已确认边界

新增"节点类型"没有注册表，全部落在字符串协议的既定阶段：

- 新变量/函数：`registerCBS` 注册到 `matcherMap`（parser.svelte.ts:984-1064），`{{名称::参数}}` 即得；`cbs.ts` 已有 40+ 内置函数（含文件、数组、字符串、日期、随机等）。
- 新资产类型：改 `assetRegex` 与 `parseAdditionalAssets` 的 switch，并同步 DOMPurify 的 `ADD_TAGS`/`ADD_ATTR` 与 `x-risu-` class 前缀白名单。
- 新正文标记（如 `<Thoughts>`、`<tool_call>`）：在 `parseThoughtsAndTools` 加正则或配对扫描，输出受清洗白名单约束的 HTML。
- 脚本层：正则脚本按 `editinput`/`editoutput`/`editdisplay`/`editprocess` 四模式作用于文本（另有 `edittrans` 翻译正则）；Lua 触发器（`triggerscript`）提供同名模式与按钮触发；插件 V2 提供 `addRisuScriptHandler` 四模式钩子和 `chatOutput` 监听器；插件面板（`chatPanelStore`）的 HTML 直接 `{@html}` 渲染，独立于消息管线。
- 新消息壳主题：`guiHTML` 模板是白名单标签转译，新增标签需要扩展 `renderGuiHtmlPart`。

已确认边界：

- 消息角色只有 user/char 两值；reasoning、工具、附件都借道正文文本标记，展示层不维护独立状态机。
- 窗口化卸载是彻底的（unmount），离屏消息不保留 DOM 状态；挂载/卸载由非加密哈希驱动，哈希冲突或 reloadPointer 变化会导致非预期重挂载（静态推断，未实测）。
- 流式三档中 `balanced`/`strong` 的合帧器只在 `isStreaming` 期间生效；脚本修改消息文本的 `@@inject` 等动作在合帧期间以累计全文为输入，每帧从零开始而非增量。
- `Message.svelte` 重写计划停留在 TODO；`VisualNovel` 目录与 AGENTS.md 描述不符（本快照中不存在）；`LiteUI` 目录只有角色卡 hub 组件（`LiteMain.svelte` + `LiteCardIcon.svelte`），聊天仍复用 `DefaultChatScreen`，不是独立的渲染变体。

## 设计取舍与已确认边界

Risuai 把"渲染"定义为字符串变换链，而不是组件树：一切内容（正文、reasoning、工具、资产、交互按钮）都以文本形式进入 `data`，由同一管线依次处理。这个取向与角色卡资产、正则脚本、Lua 触发器生态一致，也与 SillyTavern 的兼容面同向；代价是每次显示更新都要重走整条链。

显示侧事实源是消息 `data` 本身：编辑、翻译、partial edit 都把结果写回 `data`，重新解析渲染，没有独立的显示层缓存（除 `ChatBody` 的 `lastParsed` 瞬时值）。哈希窗口把"哪些消息在 DOM 中"与"每条消息的显示参数"编码为差量依据，流式期间用空 data 哈希保住实例，收尾时用真实 data 哈希触发整条重挂载——这是本仓库把流式"临时显示"与"最终渲染"分开的手段，与 strong 模式的原样文本配合，流式过程可以完全不执行富文本管线。

内容边界按两个域划分：普通消息正文受 DOMPurify 白名单与 CSS 作用域约束（可含样式、YouTube iframe，不可含脚本）；插件域在沙箱 iframe 中运行。主文档无 CSP，正文清洗完全依赖 DOMPurify 配置本身。

## 未验证事项

- Svelte 5 深层 `$state` 代理的失效传播语义：`message[i].data` 赋值与 `reloadKeys` 自增如何使 `Chats.svelte` 的 `$effect` 重跑，静态代码只能确认这是设计上的通知点，未安装依赖验证具体信号行为。
- 流式合帧的实测帧耗时：每次合帧对累计全文跑完整管线（含逐块 hljs 高亮）在长回复下的表现未运行测量；`balanced`/`strong` 的实际性能差未实测。
- strong 模式下流式显示与最终渲染的内容差异（脚本改写、Markdown 收尾）在运行中的观感未验证。
- `trimUntilPunctuation`、`pickHashRand`、资产模糊匹配等边界行为未运行验证。
- 自动播放的 `autoplay` 视频/音频受浏览器策略影响，实际行为未验证。
- 消息壳层与操作栏的键盘可用性未验证（多个点击元素只有 click 处理，依赖 `a11y_*` ignore 注释）。
- DOMPurify hook 组合（style 二次恢复、blob: src 保留、iframe 白名单）对攻击语料的行为未验证。
- Tauri（`convertFileSrc`/`asset.localhost`）与 Web（hub URL/SW 缓存）两种部署下资产 URL 的解析差异未运行对比。

## 关键源码索引

| 文件 | 关键职责 |
|---|---|
| `src/ts/parser/parser.svelte.ts` | 资产/inlay/Thoughts/工具解析、markdown-it + KaTeX + hljs、DOMPurify hook、CSS encode/decode、`risuChatParser` 变量与块解析 |
| `src/ts/parser/partialEdit.ts` | 块级部分编辑的原文区间匹配（exact/anchor/fuzzy/bigram） |
| `src/ts/parser/chatML.ts` | ChatML 文本 → OpenAI 消息（上下文侧，含 `<Thoughts>` 提取） |
| `src/ts/process/index.svelte.ts` | 生成编排：流式 reader、125ms+rAF 合帧、`editoutput` 调用、收尾与监听器 |
| `src/ts/process/scripts.ts` | `processScriptFull`：Lua 触发器 + 插件钩子 + 正则脚本 + 脚本缓存 |
| `src/ts/process/inlayScreen.ts` | `<Emotion>`/`<ImgGen>` 屏幕命令转 inlay |
| `src/ts/process/files/inlays.ts` | inlay 资产库（localforage、缩放、blob 迁移） |
| `src/ts/process/mcp/mcp.ts` | `<tool_call>` 文本协议的生产与消费 |
| `src/ts/chatLoadPages.ts` | 窗口默认值（30/15）与归一化 |
| `src/lib/ChatScreens/Chat.svelte` | 消息壳、主题分支、操作栏、复制、`guiHTML` 转译、按钮触发器 |
| `src/lib/ChatScreens/ChatBody.svelte` | `ParseMarkdown` 调用、翻译态、strong 原样文本 |
| `src/lib/ChatScreens/Chats.svelte` | 哈希差量挂载/卸载、流式实例更新、滚动 |
| `src/lib/ChatScreens/DefaultChatScreen.svelte` | 输入区、`loadPages` 管理、滚动加载、跳转、截图 |
| `src/lib/ChatScreens/PartialEditController.svelte` | 块级/拖选编辑 UI 与保存回写 |
| `src/ts/observer.svelte.ts` | 代码块右键复制/下载、`risu-ctrl` 音频 |
| `src/ts/plugins/apiV3/factory.ts` | 插件沙箱 iframe、CSP、postMessage 桥 |
| `src/ts/storage/database.svelte.ts` | `Message`/`Chat`/`StreamingDisplayOptimizationMode` 类型 |

## 关键位置

- 流式 reader 与合帧：`src/ts/process/index.svelte.ts:1591-1753`
- 消息壳正文渲染：`src/lib/ChatScreens/Chat.svelte:420-464`
- 显示层解析调用：`src/lib/ChatScreens/ChatBody.svelte:66-170, 261-268`
- 哈希差量挂载：`src/lib/ChatScreens/Chats.svelte:65-167`
- 窗口默认值：`src/ts/chatLoadPages.ts:1-2`
- Markdown 管线总入口：`src/ts/parser/parser.svelte.ts:736-777`
- DOMPurify hook：`src/ts/parser/parser.svelte.ts:46-119`
- 清洗与样式恢复：`src/ts/parser/parser.svelte.ts:779-799, 900-968`
- 资产与 inlay 解析：`src/ts/parser/parser.svelte.ts:482-597, 666-701`
- 变量解析器：`src/ts/parser/parser.svelte.ts:1538-1812`
- 插件沙箱：`src/ts/plugins/apiV3/factory.ts:434-439, 784-788, 894-921`
- 表情状态写入：`src/ts/process/scripts.ts:184-206`
- 窗口滚动加载：`src/lib/ChatScreens/DefaultChatScreen.svelte:572-585`
