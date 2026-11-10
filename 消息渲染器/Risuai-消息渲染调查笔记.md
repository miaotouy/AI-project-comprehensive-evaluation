# Risuai 消息渲染调查笔记

> 调查对象：`https://github.com/kwaroran/Risuai`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`39f1ac1472d0ef6907ee933c4cf25182ee2aec9f`（分支：`main`）
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

- 列表窗口化：默认只挂载最近 30 条，滚到顶部时每次再追加 15 条；消息以哈希作差量依据挂载或卸载，窗口默认值与哈希窗口逻辑见 `chatLoadPages.ts:1-2` 和 `Chats.svelte:65-167`。
- 富文本能力集中在字符串协议上：资产占位符、inlay 图片嵌入、思考与工具调用标记、KaTeX 公式、按需加载的 highlight.js，以及可用 `.chattext` 限定作用域的消息内 `<style>`。
- 特色能力：角色表情图系统（状态存于 `CharEmotion`，由 waifu 主题的 `TransitionImage` 呈现）、Stable Diffusion 图生成 inlay、可定制的 HTML 消息壳主题、消息级 Lua 触发器按钮。
- 承载边界：正文先经 DOMPurify 清洗，class 统一加 `x-risu-` 前缀，iframe 只放行 YouTube embed，href 只放行 http(s)；消息 CSS 靠 `.chattext` 选择器前缀限定作用域；插件运行在不带 allow-same-origin 的沙箱 iframe 中，并自带 CSP。
- 主文档的 CSP meta 在 `index.html` 中处于注释状态，页面级 CSP 未启用。

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

渲染上下文由组件参数传递：消息壳接收消息对象、角色、索引、角色资产、首条标记与生成信息等属性，其中角色参数经 `createSimpleCharacter` 裁剪，只保留脚本与资产。变量解析器按消息角色与首条身份两条件切换解析行为（`CbsConditions`，`src/ts/parser/parser.svelte.ts`）。

## 2. 流式数据到 UI 的更新链

流式消费端位于 `src/ts/process/index.svelte.ts:1591-1753` 的生成入口内：请求层返回 ReadableStream，循环读取逐 chunk 更新累计结果。三档优化模式的类型 `StreamingDisplayOptimizationMode` 定义在 `database.svelte.ts:28`，取值在生成开始时写入会话，生成结束后清除。

三个档位的差异集中在「多久处理一次」与「流式期间跑不跑正则脚本」：

| 档位 | chunk 缓冲 | 每次 flush 的正文处理 | 界面显示 |
|---|---|---|---|
| off | 无 | 每 chunk 立即 `editoutput` 脚本 + 全量 Markdown | 全量渲染 |
| balanced | 125ms 定时器 + rAF 合帧（`scheduleStreamingDisplayFlush`，`index.svelte.ts:1667-1681`） | 累计全文 `editoutput` + 全量 Markdown | 全量渲染 |
| strong | 同上 | 流式期间跳过 `editoutput`，仅 trim 后直接写入 | `rawStreamingText` 原样文本（`whitespace-pre-wrap`，`ChatBody.svelte:262`），不做任何 Markdown |

合帧器是串行的：`flushStreamingDisplay` 用 `streamingFlushPromise` 保证同一时刻只有一个处理中，期间新到达的 chunk 置排队标记，处理完再取最新值，丢弃中间帧。off 模式下无合帧，每个 chunk 都同步跑一遍正文脚本，结果直接写回消息数据。开启 removeIncompleteResponse 设置时，会在写入前把文本截到最后一个标点。

每次写入后递增 `character.reloadKeys`，配合对 `DBState` 深层状态对象的赋值，这是向 UI 传递变化的通知点（该失效在 Svelte 5 代理中的确切传播语义未运行验证，见文末）。

会话数据变化后，列表组件的 `$effect` 重跑消息更新逻辑（`Chats.svelte:99,200-227`）。对最后一条角色消息，只要会话仍在流式且优化模式为 balanced 或 strong，哈希就不计入正文数据，于是每个 chunk 更新都不改变哈希，命中已挂载实例，改为调用实例方法传入最新文本，跳过重挂载。随后消息壳在 `$effect.pre` 中重新解析变量，正文组件重走一遍完整 Markdown 管线。

收尾阶段（`index.svelte.ts:1727-1753`）：先强制 flush 剩余内容；strong 模式此时补跑一次正文脚本；随后结束流式状态并清除优化模式。哈希随即纳入最终正文数据，与流式期间的哈希不同，整条消息被卸载并重新挂载，以完整管线渲染最终文本，因此 strong 模式下流式期间显示的未处理原文只影响流式过程，最终画面仍是完整渲染结果。完成后还依次执行屏幕命令替换（`<Emotion>`/`<ImgGen>`）、插件输出钩子与可选的自动 TTS。

## 3. 消息列表、窗口化与滚动

聊天屏组件维护窗口大小状态，初始显示量默认 30 条，可由数据库字段 `chatLoadInitialPages` 覆盖（[默认值与配置读取](<../../Risuai/src/ts/chatLoadPages.ts#L1-L23>)）。

滚动容器是 `flex-col-reverse` 的纵向滚动 div：滚到顶部 100px 内且消息数大于当前窗口时，窗口按配置追加消息，默认每次追加 15 条，追加量由 `chatLoadAdditionalPages` 控制（[窗口扩展入口](<../../Risuai/src/lib/ChatScreens/DefaultChatScreen.svelte#L572-L585>)）。

`Chats.svelte` 是窗口化的执行者，它不用 `{#each}` 而是命令式挂载：

1. 对 `[length-loadPages, length)` 范围内的每条消息计算 32 位哈希（`hashCode`，输入为 data、chatId、idx、头像尺寸、disabled、reloadPointer）。
2. 与上一轮的哈希集合比较：新哈希 → `mount(Chat, {target: div})` 并插到前一个已挂载节点之后；既有哈希 → 调用实例的 `updateStreamingDisplay`（仅流式场景有意义）。
3. 集合差集 → `unmount` 并移除 DOM（`Chats.svelte:152-163`）。

滚动锚定依赖两条布局事实：新消息始终 prepend 到最旧消息之前，即落在视觉底部；加载更早历史时新节点插在既有节点之后，即位于视口上方。两个方向都不改变当前可见内容，滚动位置因此天然保持。用户不在底部且开启了 `autoScrollToNewMessage` 时，新消息不触发自动滚动，改为显示「新消息」按钮，滚到底部后按钮消失。书签跳转先临时把窗口大小扩到能覆盖目标索引的范围，再轮询 `[data-chat-index]` 元素并滚动到该元素；截图则把窗口设为无限大，逐条 canvas 拼接（`DefaultChatScreen.svelte:73-135,449-503`）。

## 4. 消息壳层与角色分派

消息壳只有一个组件 `Chat.svelte`（1157 行），同时承载用户、角色、评论、首条问候与群聊消息，按角色、评论标记、首条身份与问候语属性分派。`src/lib/ChatScreens/Message.svelte` 是标注"future-proofing 重写"的 27 行 TODO 存根，未被引用。

壳层渲染按主题分四路（`Chat.svelte:1068-1147`）：

- `mobilechat`：气泡式，头像在角色侧，用户消息右对齐。
- `cardboard`：卡片式，大头像 + 名称 + 固定高度正文区。
- `customHTML`：以 `DBState.db.guiHTML` 字符串作为消息壳模板，经 DOMParser 解析后由 `renderGuiHtmlPart` 递归转译成 Svelte 组件（`Chat.svelte:220-229,918-1056`）。模板只接受约二十种白名单标签，未知标签降级为 div，A 标签的 href 只放行 https。四个特殊标签分别替换为：
  - `RISUTEXTBOX` → 正文框
  - `RISUICON` → 发送者头像
  - `RISUBUTTONS` → 操作栏
  - `RISUGENINFO` → 生成信息
- 默认：头像 + 名称行 + 操作栏 + `genInfo`（模型信息、LLM 翻译状态）+ 正文。

正文容器是带 `chattext` class 的 span，内部以 `{#key}` 包住正文组件，键值为重挂载指针；触发器、角色切换等场景自增该指针，指针一变整块正文重挂载。首条消息由聊天屏直接渲染一个独立消息壳，支持问候语分页与 `{{none}}`、`{{blank}}`、空串三种占位文案；评论消息按分支来源数据渲染成分支跳转链接。操作栏集中复制、翻译、编辑、TTS、删除、书签、分支、禁用、禁用以上与 reroll 按钮，桌面端主要按钮直接展示，次要按钮收进弹出菜单（`Chat.svelte:425`）。

## 5. Markdown、代码与富文本管线

`ParseMarkdown`（`src/ts/parser/parser.svelte.ts:736-777`）是正文管线的总入口，处理顺序本身是渲染协议：

1. 资产替换：把 `{{img::名称}}` 一类占位符换成对应的文件 src，覆盖 raw、path、img、video、audio、bgm、bg、emotion、asset 等十余种类型。资产名先在角色的 `additionalAssets` 中精确查找；未命中且 `legacyMediaFindings` 关闭时，改用 Levenshtein 模糊匹配，距离上限由 `assetMaxDifference` 限定；同一资产存在多条路径时，按会话做确定性随机选择。出现多选项时，这一步会在脚本处理后再跑一次，覆盖脚本新写出的占位符（`parser.svelte.ts:408`）。
2. 脚本处理：由 `processScriptFull` 依次运行 Lua editDisplay 触发器、插件的 `pluginV2.editdisplay` 钩子，以及全局、角色和模块三级正则脚本（`scripts.ts:99-387`）。
3. inlay 资产：把 `{{inlay::id}}`、`{{inlayed::id}}` 和 `{{inlayeddata::id}}` 三种引用换成本地 blob URL 的图片、视频或音频标签（`parser.svelte.ts:666-701`）。
4. 思考与工具标记：深度配对的 `<Thoughts>` 折叠为 details/summary 结构；`<tool_call>` 标签（id 与名称之间以私有区字符分隔）替换成一行带 `x-risu-tool-call` class 的提示（`parser.svelte.ts:713-734`）。
5. 样式保护：把 `<style>` 的内容做 hex 编码并包进 `<risu-style>`，避免 DOMPurify 直接处理样式内容。
6. Markdown 与高亮：先处理公式，再渲染正文，最后替换代码围栏占位节点。
   - 公式由 `katex.renderToString` 把 `$$...$$` 替换成 MathML（关闭 displayMode）。正文交给 markdown-it，开启 html 与 breaks、启用 typographer，引号经占位符机制处理（[公式与正文转换](<../../Risuai/src/ts/parser/parser.svelte.ts#L152-L204>)）。
   - 带语言标记的代码围栏交给第二个 markdown-it 实例输出占位节点，之后逐块按需加载 highlight.js 语言并生成高亮块，switch 映射 18 种语言。
   - 未知语言转义为纯文本；显式标记为 `risuerror` 的围栏输出错误面板。高亮处理发生异常时进入空 catch，错误面板由特殊语言标记触发（[语言分派与异常分支](<../../Risuai/src/ts/parser/parser.svelte.ts#L373-L401>)）。
7. 清洗收尾：正文渲染时调用 `trimMarkdown`。普通内容直接经 DOMPurify 清洗；含 `risu-style` 时先取得清洗后的 DOM，再把其中真实的样式节点解码并原位替换为 style。清洗只作用于 HTML 结构，样式以解码后的节点替换回去，因此文本或 SVG data URL 中出现的类似标记不会被误删（`parser.svelte.ts:779-834,966-1003`）。

两个 markdown-it 实例都 `disable(['code'])`（缩进代码块规则），正文行内代码与围栏行为由上述占位机制统一处理。markdown-it 的 typographer 把引号替换为 PUA 字符，随后按 `customQuotes`/`blockquoteStyling` 设置决定是原样还原还是包成 `<mark risu-mark>` 引用样式。

`risuChatParser`（parser.svelte.ts:1538-1812）是变量层，按语法元素划分能力：

- 变量与函数调用：`{{变量}}` 直接取值；`{{函数::参数}}` 调用经 `registerCBS` 注册的函数，注册时写入内部匹配表，文件类函数在显示模式下输出文件名块；`{{call::}}` 复用已定义函数，`?:` 前缀表示按表达式计算。
- 控制块：按语法元素分为条件、循环、函数定义、转义与纯文本、代码归一化几类，块嵌套上限为 512 层数组与 20 层调用栈。
  - 条件：`{{#if}}` 与 `{{#when}}`，判断项包括 not、and、or、is、var、toggle 与比较运算
  - 循环：`{{#each}}`
  - 函数定义：`{{#func}}`
  - 转义与纯文本：`{{#escape}}`、`{{#pure}}`
  - 代码归一化：`{{#code}}`
- 兼容归一：解析前把 `<(user|char|bot)>` 写法与 `{{user}}`、`{{char}}` 占位统一替换。

Chat 的 `displaya` 以 `visualize: true` 调用它，使 `{{file::}}` 这类函数走显示分支。

## 6. 工具、reasoning、附件与自定义节点

- 工具调用：请求层把 API 返回的工具调用序列化成 `<tool_call>` 文本，id 与名称以 `\uf100` 分隔；展示层再把它换成一行只读提示，带 🛠️ 图标与 `x-risu-tool-call` class，没有工具卡、审批或展开交互。工具参数与结果都在上下文侧处理，不进入消息正文（`src/ts/process/mcp/mcp.ts:359`）。
- reasoning：`<Thoughts>` 标签折叠成可展开的 details，默认文案取自语言文件的 `cot` 条目，折叠行为在流式与非流式下一致。
- 资产 inlay：`{{inlay::id}}` 系列引用存放在 localforage 中的 inlay 库；图片上传时经 canvas 缩放到不超过 1024×1024，读取时迁移为 Blob 并缓存 object URL。输入框粘贴图片与菜单里的「发布文件」都走 `postChatFile`，把 inlay id 写入消息文本；多模态模型再把 inlay 图片以 `{{inlayed::}}` 形式拼进提示，是否支持由 `supportsInlayImage` 判定（`src/ts/process/files/inlays.ts:30-33,225-228`）。
- 表情图：`{{emotion::名称}}` 按角色的表情图列表解析成图片。正则脚本里的 `@@emo` 指令把表情压入全局表情状态，waifu 与 waifuMobile 主题的聊天屏据此驱动右侧表情组件：切换时新旧两张图交叉淡入淡出，多表情横向分格，叠加显示由 `emp` 样式负责；桌面聊天面板可拖动调整该区域大小（`scripts.ts:184-206`）。
- 屏幕模式：角色的 `viewScreen` 取值决定命令类型。emotion 时模型按指令输出 `<Emotion="...">` 命令，解析层把它转成表情引用；imggen 时 `<ImgGen="...">` 先显示「[Generating...]」占位，图片由 Stable Diffusion 异步生成后写入 inlay 库，再替换成 inlay 引用（`src/ts/process/inlayScreen.ts:7-50`）。
- 文件：`{{file::名称::base64}}` 在显示模式下只输出一个带 `risu-file` class 的文件名块，内容解码发生在上下文侧（`cbs.ts:972-981`）。
- 音频：`{{bgm::}}` 输出一个隐藏的 `risu-ctrl="bgm___auto___路径"` 元素，由 `observer.svelte.ts` 的 MutationObserver 轮询接管播放。

## 7. HTML、CSS 与内容承载边界

正文 HTML 都要先经 `trimMarkdown` 里的 DOMPurify 清洗，再交给 `{@html}` 输出；历史消息、流式渲染与翻译后重渲染共用这一个清洗点，渲染组件没有绕过它的输出路径。正文组件渲染时还会把模型名编码成零宽字符注入段落标签，但水印开关当前恒返回 false，这段逻辑在本快照中是死代码（`parser.svelte.ts:779-799,860-874`；`globalApi.svelte.ts:2333-2338`）。

DOMPurify 通过全局 hook 收紧三类行为（parser.svelte.ts:46-119）：

- 元素级 hook：iframe 只放行 `https://www.youtube.com/embed/` 前缀；img 在 `hideAllImages` 开启时换成 `/none.webp` 占位，并清理 style 里的 background-image，未开启时补上 `loading="lazy"` 与 `decoding="async"`。
- 属性级 hook：class 逐个加 `x-risu-` 前缀，`hljs` 与已带前缀的除外；href 只允许 http 与 https 并补 `target="_blank"`，其余置空；`IMG/SOURCE/VIDEO/AUDIO/STYLE` 上的 blob 与 asset 协议 src 通过 `forceKeepAttr` 保留，inlay 依赖这条规则。
- 清洗结果保留样式、受限 iframe、MathML 与交互属性，其中 `risu-form` 让普通消息保留表单触发键；直接绑定聊天变量的两个属性只在独立的 Onboarding 清洗配置里放行，普通聊天消息不启用这套扩展配置（`parser/parser.svelte.ts:779-788`）。

消息内样式标签走特殊路径（`parser.svelte.ts:930-1003`）：内容先以 hex 编码躲过 HTML 清洗，随后用 CSS 解析器还原，选择器加 `.chattext` 前缀、class 加 `x-risu-` 前缀，再把所得 CSS 放进已清洗 DOM 的真实 style 节点。这与 SillyTavern 的 custom-style 思路同类：样式留在主文档，隔离靠选择器前缀而非 Shadow DOM。解析失败时按设置回显错误文本或丢弃；`@import` 规则只有 data: 开头才被保留，保留时清空为空值 data:,。为避免样式标签提早闭合，恢复前会转义 CSS 内的 `</style` 序列。

主文档 `index.html` 的 CSP meta 处于注释状态（index.html:14），页面级 CSP 未启用。插件运行在独立沙箱 iframe（`src/ts/plugins/apiV3/factory.ts:438, 784-788, 894-921`）：sandbox 仅 `allow-scripts allow-modals allow-downloads`（无 `allow-same-origin`，保持 opaque origin），srcdoc 附带 CSP，插件与主文档通过 postMessage RPC 桥通信（`SandboxHost`）。该沙箱服务于插件 UI，不参与普通消息正文的渲染路径。iframe 内 CSP 指令如下：

- 网络与容器受限：`connect-src 'none'`、`frame-src 'none'`、`object-src 'none'`、`base-uri 'none'`。
- 脚本只认 nonce：`script-src 'nonce-*' 'wasm-unsafe-eval'`，插件代码以内联脚本注入 srcdoc 并带随机 nonce。
- 媒体类资源放宽：`img-src * data: blob:`、`font-src * data: blob:`、`media-src * data: blob:`、`style-src * 'unsafe-inline'`。

## 8. 内容交互反馈

- 复制：消息壳的复制按钮支持富文本复制。复制前重新执行一次 Markdown 解析，用 DOMParser 拆出 DOM，把引用、段落、强调按主题变量内联成样式，图片经 fetch 与 canvas 重编码为 data URL，最后用 `ClipboardItem` 同时写入纯文本与 HTML 两种剪贴板格式；成功时弹出语言包提示，异常时降级为纯文本写入并在行内显示状态。代码块复制走右键菜单，可复制全文，或按高亮节点记录的扩展名下载文件（`Chat.svelte:511-741`；`observer.svelte.ts:10-54`）。
- 编辑：整段编辑由消息壳把正文切换为 textarea；块级编辑由 `PartialEditController.svelte` 在悬停块上追加编辑与删除按钮，拖选文本也能直接编辑。保存时先把选中 HTML 转成纯文本，再用 exact、anchor、fuzzy、bigram 四级匹配定位原文区间，命中后由 `replaceRange` 替换并回写 `message.data`，随后重新渲染，匹配失败则弹窗提示（`src/ts/parser/partialEdit.ts:326-619`）。
- **消息内按钮**：消息容器捕获点击后从事件目标向上查找交互属性，命中手动触发器就直接执行，未命中则进入 Lua 按钮交互。返回结果可替换当前会话并刷新该消息的重渲染计数，群聊场景在入口处直接返回（`Chat.svelte:306-345`）。
- **消息内表单**：容器捕获 submit 事件并统一阻止浏览器的默认提交。只有带 `risu-form` 的表单且当前角色不是群聊时才继续：收集 FormData 后交给 Lua 表单交互，重复字段保留为数组，提交按钮本身也计入数据。回调收到触发键和含 data 的 JSON 元信息，可修改聊天内容并触发重绘；字段只流向 Lua 交互层（`Chat.svelte:348-385,1184-1185`；`process/scriptings.ts:1121-1126,1489-1513`）。
- 翻译：按钮在译文与原文之间切换，LLM 翻译期间显示加载旋转占位，并提供「重新翻译」「编辑翻译」入口（`ChatBody.svelte:109-149`）。翻译可发生在 HTML 格式化之前，也可在其后执行；后一条路径由 `postTranslationParse` 重新跑一遍代码高亮。
- 状态反馈：删除确认、书签命名弹窗、TTS 按钮与分支创建都复用项目既有的 alert 系统；开启 `clickToEdit` 后单击正文即可进入编辑模式。

## 9. 性能、缓存与测试

性能策略分四层：

- 列表层：窗口化（默认 30+15）限制常驻消息实例数；哈希差量挂载避免整表重渲染；流式消息在哈希中排除 data，使合帧更新只走实例方法而不是重挂载。
- 流式层：125ms + rAF 合帧丢弃中间帧；strong 模式流式期间跳过 `editoutput` 脚本与全部 Markdown 解析，只显示纯文本。
- 解析层：脚本执行结果按「脚本+数据+模式」的哈希缓存，容量上限 1000（`scripts.ts:68-93`）；文件与 blob URL、资产索引各有独立缓存，资产索引在角色切换时重建；highlight.js 语言按需 `import`，只加载实际出现的语言；正文组件内缓存上一次解析结果，翻译与角色参数未变时复用。
- 渲染层：hljs 高亮结果直接进入清洗后的 HTML，不在 DOM 上二次高亮；`{#key}` 控制 ChatBody 重挂载时机。

可确认的取舍是：每次流式合帧仍然对累计全文执行完整 Markdown 管线（含正则脚本、KaTeX、高亮与清洗），成本随单条回复线性增长；`balanced` 与 `off` 的唯一区别是合帧频率，不是重算范围。

测试：仓库使用 vitest（`package.json` 的 test 脚本），共 24 个 `*.test.ts` 文件。覆盖渲染相关的主要有：parser 的 CBS 函数（strings/loop/escapes/conditionals）、chatML、chatVar、inlay 资产读写、chatLoadPages 数值归一化、scriptings 触发器；另有 GUI 原语、请求层、翻译正则等测试。未发现针对消息壳、正文组件与列表组件的组件级测试，也没有覆盖流式合帧链路；`parser.svelte.ts` 的 DOMPurify hook 与样式解码没有直接测试文件。

## 10. 扩展方式与已确认边界

新增"节点类型"没有注册表，全部落在字符串协议的既定阶段：

- 新变量与函数：用 `registerCBS` 把回调注册进 `matcherMap` 后，正文即可用 `{{名称::参数}}` 形式调用；`cbs.ts` 已内置 40 多个函数，覆盖文件、数组、字符串、日期、随机等类别（`parser.svelte.ts:984-1064`）。
- 新资产类型：在 `assetRegex` 与 `parseAdditionalAssets` 的 switch 中加分支，并同步 DOMPurify 的 `ADD_TAGS`、`ADD_ATTR` 与 `x-risu-` class 前缀白名单。
- 新正文标记（如 `<Thoughts>`、`<tool_call>`）：在 `parseThoughtsAndTools` 中加正则或配对扫描，输出受清洗白名单约束的 HTML。
- 脚本层：正则脚本按模式作用于文本，Lua 触发器、插件 V2 与插件面板各有一套入口。
  - 正则脚本：`editinput`、`editoutput`、`editdisplay`、`editprocess` 四种模式作用于文本，另有 `edittrans` 专用于翻译
  - Lua 触发器：同名模式加按钮触发
  - 插件 V2：`addRisuScriptHandler` 四模式钩子与 `chatOutput` 监听器
  - 插件面板：HTML 由 `{@html}` 直接渲染，独立于消息管线
- 新消息壳主题：`guiHTML` 模板是白名单标签转译，新增标签需要扩展 `renderGuiHtmlPart`。

已确认边界：

- 消息角色只有 user/char 两值；reasoning、工具、附件都借道正文文本标记，展示层不维护独立状态机。
- 窗口化卸载是彻底的（unmount），离屏消息不保留 DOM 状态；挂载/卸载由非加密哈希驱动，哈希冲突或 reloadPointer 变化会导致非预期重挂载（静态推断，未实测）。
- 流式三档中 `balanced`/`strong` 的合帧器只在 `isStreaming` 期间生效；脚本修改消息文本的 `@@inject` 等动作在合帧期间以累计全文为输入，每帧从零开始而非增量。
- `Message.svelte` 重写计划停留在 TODO；`VisualNovel` 目录与 AGENTS.md 描述不符（本快照中不存在）；`LiteUI` 目录只有角色卡 hub 的两个组件，聊天仍复用 `DefaultChatScreen` 渲染。

## 设计取舍与已确认边界

Risuai 把"渲染"定义为字符串变换链，而不是组件树：一切内容（正文、reasoning、工具、资产、交互按钮）都以文本形式进入 `data`，由同一管线依次处理。这个取向与角色卡资产、正则脚本、Lua 触发器生态一致，也与 SillyTavern 的兼容面同向；代价是每次显示更新都要重走整条链。

显示侧事实源是消息 `data` 本身：编辑、翻译、partial edit 都把结果写回 `data`，重新解析渲染，没有独立的显示层缓存（除 `ChatBody` 的 `lastParsed` 瞬时值）。哈希窗口把"哪些消息在 DOM 中"与"每条消息的显示参数"编码为差量依据，流式期间用空 data 哈希保住实例，收尾时用真实 data 哈希触发整条重挂载——这是本仓库把流式"临时显示"与"最终渲染"分开的手段，与 strong 模式的原样文本配合，流式过程可以完全不执行富文本管线。

内容边界按两个域划分：普通消息正文受 DOMPurify 白名单与 CSS 作用域约束（可含样式、YouTube iframe，不可含脚本）；插件域在沙箱 iframe 中运行。主文档无 CSP，正文清洗完全依赖 DOMPurify 配置本身。

## 未验证事项

- Svelte 5 深层 `$state` 代理的失效传播语义：给 `message[i].data` 赋值、自增 `reloadKeys` 之后，`Chats.svelte` 的 `$effect` 在什么粒度上重跑，静态代码只能确认这是设计上的通知点；本次未安装依赖，具体信号行为未验证。
- 流式合帧的实测帧耗时：每次合帧都要对累计全文跑完整管线，其中包含逐块 highlight.js 高亮，长回复下的耗时未做运行测量；balanced 与 strong 两档的实际性能差距同样未实测。
- strong 模式下，流式期间的原文显示与收尾后完整渲染在内容上的差异（脚本改写、Markdown 收尾）在运行时观感如何，本次未验证。
- 截断到最后一个标点、资产路径的确定性随机选择、资产名模糊匹配等边界行为未做运行验证（`trimUntilPunctuation`、`pickHashRand`）。
- 自动播放的视频与音频受浏览器 autoplay 策略影响，实际行为未验证。
- 消息壳层与操作栏的键盘可用性未验证：多个点击元素只绑定了 click，依赖 `a11y_*` 的 ignore 注释。
- DOMPurify 的几项 hook 组合（样式二次恢复、`blob:` src 保留、iframe 白名单）对攻击语料的行为未验证。
- 两种部署下资产 URL 的解析差异未做对比：Tauri 走 `convertFileSrc` 与 `asset.localhost`，Web 走 hub URL 与 Service Worker 缓存。

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
