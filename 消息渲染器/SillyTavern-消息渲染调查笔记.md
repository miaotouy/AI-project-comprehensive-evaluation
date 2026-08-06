# SillyTavern 消息渲染调查笔记

> 调查对象：`E:\works\git\SillyTavern`
>
> 调查更新日期：2026-07-29
>
> 代码快照：`8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8`（分支：`release`）
>
> 调查方式：只读源码梳理，未修改目标仓库
>
> 调查范围：消息模型、Markdown/富文本、流式更新、列表和扩展渲染机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

SillyTavern 使用命令式前端流水线渲染消息：全局 `chat` 数组提供数据，jQuery 克隆 HTML 模板，Showdown 转换 Markdown，DOMPurify 清洗 HTML，随后由多个模块补充 reasoning、媒体、代码高亮和交互状态。

主链路如下：

1. 消息对象先写入全局 `chat` 数组。
2. `addOneMessage()` 或 `redisplayChat()` 调用 `updateMessageElement()`。
3. `updateMessageElement()` 克隆 `#message_template .mes`，填充元数据和各内容区域。
4. 正文由 `messageFormatting()` 依次执行宏替换、正则脚本、Markdown 修复、Showdown 和 DOMPurify。
5. reasoning 与媒体从 `message.extra` 读取，写入正文之外的专用 DOM 容器。
6. Highlight.js、复制按钮、swipe 控件和扩展事件在正文进入 DOM 后补充行为。

流式输出复用与静态消息相同的 Markdown 格式化函数。`StreamingProcessor` 默认以 30 FPS 节流，每次用当前累计全文重新调用 `messageFormatting()`，再覆盖 `.mes_text.innerHTML`。流结束时保留现有消息 DOM，并在其上完成代码高亮、reasoning、媒体、swipe、事件和持久化收尾。

代码中可以确认以下实现特点：

- 历史、普通新消息和流式消息最终共用同一个正文格式化函数，显示语义较一致。
- reasoning、附件、媒体、偏置、计时和 token 数都有明确的旁路字段及 DOM 区域。
- HTML 和 `<style>` 是受支持的消息能力；DOMPurify 负责 HTML 边界，自定义 CSS parser 负责样式作用域。
- `CHARACTER_MESSAGE_RENDERED` / `USER_MESSAGE_RENDERED` 等事件构成扩展层的主要接入面。
- 历史仅做截断式分页，不做消息 DOM 虚拟化。

DOMPurify 会移除消息脚本，但消息 `<style>` 会在净化后被重新解码成主页面中的真实样式标签，且服务端明确关闭 CSP。代码尝试把选择器限定到 `.mes_text` 并默认阻止外链媒体，因此主要风险落在这条自定义 CSS 安全边界上。

## 总体架构

```text
Chat JSONL / 当前生成结果 / slash command / extension
  -> 全局 chat: ChatMessage[]
  -> addOneMessage()                 单条新增/替换
     或 redisplayChat()              历史批量显示
  -> updateMessageElement()
       -> clone #message_template .mes
       -> getMessageTextHTML()
            -> messageFormatting()
       -> updateReasoningUI()
       -> appendMediaToMessage()
       -> .mes_text.innerHTML = messageHTML
       -> Highlight.js + copy button
       -> swipe / timestamp / token / action UI
  -> append/prepend 到 #chat
  -> CHARACTER_MESSAGE_RENDERED / USER_MESSAGE_RENDERED 等事件
  -> 扩展继续响应或修改 UI
```

流式链路为：

```text
API async generator
  -> StreamingProcessor.generate()
  -> STREAM_TOKEN_RECEIVED（每个流快照）
  -> Stopwatch（默认 30 FPS）
  -> cleanUpMessage() + 补齐未闭合 Markdown 标记
  -> 更新 chat[messageId].mes / reasoning / timer / token
  -> messageFormatting(累计全文)
  -> 覆盖现有 .mes_text.innerHTML
  -> 完成时 Highlight.js / media / swipe / rendered events / save chat
```

`public/scripts/streaming-display.js` 还提供浮层式 `StreamingDisplay`。它服务于连接管理器等非主聊天生成场景，不属于 `#chat` 中 assistant 消息的核心流式实现，但同样复用 `messageFormatting()`。

## 数据模型

消息的核心类型在 `public/global.d.ts`：

```ts
interface ChatMessage {
  name?: string;
  mes?: string;
  title?: string;
  send_date?: MessageTimestamp;
  gen_started?: MessageTimestamp;
  gen_finished?: MessageTimestamp;
  is_user?: boolean;
  is_system?: boolean;
  force_avatar?: string;
  swipes?: string[];
  swipe_info?: SwipeInfo[];
  swipe_id?: number;
  extra?: ChatMessageExtra;
}
```

渲染相关的 `extra` 字段主要有：

| 字段 | 渲染用途 |
|---|---|
| `display_text` | 覆盖 `mes` 的可见正文，但保留原始消息值 |
| `reasoning` | reasoning 专用内容 |
| `reasoning_display_text` | reasoning 的显示覆盖值 |
| `files` | 文件附件列表 |
| `media` | 图片、视频、音频附件列表 |
| `inline_image` | 控制含媒体时正文是否隐藏 |
| `media_display` / `media_index` | 媒体列表或画廊及当前项 |
| `bias` | 单独显示的 prompt bias |
| `api` / `model` | 时间戳和 reasoning 标题旁的模型信息 |
| `token_count` | token 计数显示 |
| `tool_invocations` | 标记该消息是工具调用消息 |
| `uses_system_ui` | 为内置系统消息保留有限的主 UI class |

工具调用并没有在消息正文中渲染成独立工具卡。`tool_invocations` 主要作为上下文和递归调用记录；消息层只给对应 `.mes` 增加 `toolCall` class，纯工具调用且无正文/reasoning 时还会暂时隐藏消息。

## 消息骨架

静态模板位于 `public/index.html` 的 `#message_template`，主要结构是：

```text
.mes
  .mesAvatarWrapper
    avatar / message id / timer / token counter
  .swipe_left
  .mes_block
    .ch_name
      name / timestamp / message actions / edit actions
    details.mes_reasoning_details
      summary / reasoning actions
      .mes_reasoning
    .mes_text
    .mes_media_wrapper
    .mes_file_wrapper
    .mes_bias
  .swipe_rightBlock
```

这套消息骨架由命令式 DOM 操作装配。`updateMessageElement()` 克隆模板后，使用 `.attr()`、`.text()`、`.html()`、class toggle 和事件监听逐项写入。头像、名称和普通元数据使用 `.text()` 或属性 API；已经格式化并清洗过的正文、reasoning 和 bias 使用 HTML 注入。

## 历史消息

### `printMessages()` 与 `redisplayChat()`

`printMessages()` 根据 `power_user.chat_truncation` 只显示最后一段消息，默认值是 100。若历史更长，则在顶部添加 `#show_more_messages`。

`redisplayChat()`：

- 删除指定 index 之后的现有消息 DOM。
- 对目标 slice 中每条消息同步调用 `updateMessageElement()`。
- 收集原生元素后一次性 append，减少 DOM 插入次数。
- 批量完成后刷新 swipe、样式 pin、标签和编辑箭头。

“加载更多”同样批量创建一段消息并 prepend/insert，同时通过新旧 `scrollHeight` 差值维持用户视口。

这属于截断式分页，而不是虚拟列表：已经显示的消息仍长期保留在 DOM 中。`chat_truncation = 0` 时可退化为一次显示全部历史。

## 单条消息装配

### `addOneMessage()`

调用者应先把消息写入 `chat`，再调用 `addOneMessage()`。该函数负责：

- 推导消息 ID，或接受 `forceId` / `insertBefore` / `insertAfter`。
- 普通消息创建新模板；swipe 则复用原节点并执行更新。
- append、前插或后插消息节点。
- 维护唯一的 `.last_mes`。
- 刷新 swipe 控件、角色标签、编辑箭头和滚动位置。

### `updateMessageElement()`

这是单条消息的结构装配中心，主要顺序为：

1. 选择 persona、角色、群聊成员或系统头像。
2. 计算 timestamp、timer、token count 和正文 HTML。
3. 设置 `mesid`、`swipeid`、`is_user`、`is_system`、`type` 等 DOM 属性。
4. 以文本方式填充名字、时间和计数。
5. 格式化并写入 bias。
6. 初始化 reasoning UI 和模型图标。
7. 标记小型系统消息、工具调用消息等状态。
8. 装配媒体和文件。
9. 把已清洗的正文写入 `.mes_text`。
10. 对代码块执行 Highlight.js 并添加复制按钮。
11. 更新 swipe 计数。

`updateMessageBlock()` 是较轻量的局部重渲染入口，用于翻译、reasoning 编辑等场景。它重写正文，然后刷新 reasoning、代码按钮和媒体。

## 正文格式化流水线

核心函数是 `public/script.js` 中的 `messageFormatting()`。其处理顺序本身就是渲染协议：

```text
raw message
  -> 首条角色消息宏替换
  -> prompt bias 隐藏
  -> regex extension（USER_INPUT / AI_OUTPUT / REASONING 等 placement）
  -> fixMarkdown()
  -> 可选 encode_tags：转义 < 和 >
  -> reasoning 前后缀保护
  -> 引号转 <q>（跳过 style / code）
  -> align* 转 $$
  -> Showdown Markdown -> HTML
  -> 代码块换行及 &amp; 修正
  -> 可选移除角色名前缀
  -> <style> 编码为 <custom-style>
  -> DOMPurify.sanitize()
  -> <custom-style> 解码和 CSS 作用域改写
  -> HTML string
```

### Showdown 配置

`reloadMarkdownProcessor()` 创建全局 Showdown converter，开启：

- emoji
- mid-word underscore 保留
- 图片尺寸语法
- table
- underline
- simple line breaks
- strikethrough
- 缩进子列表兼容选项

同时注册两个本地扩展：

- `markdownUnderscoreExt()`：处理下划线语义。
- `markdownExclusionExt()`：处理 Markdown 排除标记。

核心渲染链未提供 Mermaid 或 KaTeX 后处理。`\begin{align*}` 仅被改写为 `$$`；如果没有额外扩展接管，核心本身不会把数学表达式排版成公式。

### Regex 扩展参与渲染

正文进入 Markdown 前会调用 `getRegexedString()`。placement 根据消息类型区分：

- user：`USER_INPUT`
- assistant：`AI_OUTPUT`
- reasoning：`REASONING`
- narrator/slash command：`SLASH_COMMAND`

它还计算消息在所有非系统消息中的相对 depth。因此 regex 脚本不仅能改写最终文本，还能按消息深度和角色生效。由于这一步发生在 Markdown 与 DOMPurify 之前，regex 产生的 HTML 仍会进入后续清洗。

### `display_text` 覆盖

标准装配优先使用 `extra.display_text`，使翻译等功能能改变可见文本而不覆盖 `mes`。这里存在一个小的不一致：

- `getMessageTextHTML()` 使用 `display_text || mes`。
- `updateMessageBlock()` 使用 `display_text ?? mes`。

因此 `display_text: ''` 在完整装配时会回退到 `mes`，在局部更新时却会显示为空。若扩展把空字符串当成合法显示覆盖值，两条路径结果不同。

## HTML 净化与 CSS

### DOMPurify

所有标准正文和 reasoning 最终都会调用 DOMPurify。配置额外带有 `MESSAGE_SANITIZE`，供全局 hook 判断是否处于消息清洗场景。

消息 hook 主要完成三件事：

1. 链接统一为 `target="_blank"` 和 `rel="noopener"`。
2. 普通 HTML class 改名为 `custom-*`，避免直接命中主界面 class；Font Awesome、`note-*` 和 `monospace` 例外。
3. 默认阻止 HTML 中跨源的 `img`、`audio`、`video`、`source`、`track`、`embed` 和 `object` 资源。

内置 welcome、welcome prompt 和 assistant note 可设置 `uses_system_ui`。它只允许 `BUTTON` / `DIV` 上的 `menu_button` class 保持原名，以便可信的内置模板接入主 UI；普通模型消息不会得到这个例外。

### `<style>` 的特殊路径

为了保留消息自定义样式，代码在 DOMPurify 前把 `<style>` 内容 URL 编码进 `<custom-style>`。净化完成后，再使用 `@adobe/css-tools` 解析 CSS 并恢复真实 `<style>`。

恢复阶段会：

- 删除 CSS `@import`。
- 给选择器加 `.mes_text ` 前缀。
- 把 CSS 中的 `.foo` 同步改成 `.custom-foo`，与 HTML class hook 对齐。
- 外部媒体未获许可时，删除 value 中包含 `://` 的 declaration。

这比直接放行 `<style>` 更稳健，但它仍不是浏览器安全隔离：样式标签位于主文档，且 CSS 规则由自定义重写器约束，而不是 Shadow DOM 或 sandbox iframe。

### CSP 状态

`src/server-main.js` 使用 Helmet，但明确设置 `contentSecurityPolicy: false`。因此 CSP 不为消息 HTML/CSS 提供第二道限制。消息脚本的主要保护依赖 DOMPurify；CSS 的主要保护依赖上述 selector 和 URL 改写逻辑。

## Reasoning

reasoning 是 `message.extra.reasoning` 中的独立字段，不依靠从普通正文中渲染 `<think>` 标签。

`ReasoningHandler` 负责：

- 从流状态或正文前后缀中提取/更新 reasoning。
- 维护 None、Thinking、Done、Hidden 等状态。
- 记录 reasoning 时长。
- 将内容以 `isReasoning = true` 调用 `messageFormatting()`。
- 更新 `<details class="mes_reasoning_details">`、标题、展开状态和编辑按钮。
- 流结束时发送 `STREAM_REASONING_DONE`。

reasoning 与正文使用相同的 Markdown、regex 和 DOMPurify 管线，但 regex placement 为 `REASONING`，且跳过首条角色消息宏替换。

## 媒体与文件

`appendMediaToMessage()` 处理结构化附件，而不是解析正文中的 Markdown 图片：

- 先把旧版单值 `image` / `file` / `video` 兼容成数组接口。
- `extra.media` 支持 image、video、audio。
- 媒体可按 LIST 全部显示，也可按 GALLERY 只显示当前项。
- audio 使用独立 `AudioPlayer`。
- `extra.files` 克隆文件模板并以 `.text()` 写入文件名和大小。
- 重新装配 audio/video 时会尝试保存和恢复播放位置、暂停状态。
- 图片和媒体加载采用 `Promise.race` 与短超时，不阻塞整条消息渲染。
- 根据 `SCROLL_BEHAVIOR` 调整或保持聊天滚动位置。

外链媒体开关的 DOMPurify hook 约束的是消息 HTML 内资源；结构化 `extra.media[].url` 则直接赋给模板元素的 `src`，属于另一条信任路径。

## 代码块

Showdown 生成 `<pre><code>` 后，`addCopyToCodeBlocks()` 对每个代码块执行：

1. `hljs.highlightElement()`。
2. 在 code 元素内加入 Font Awesome copy icon。
3. 点击后读取整个 code 的 `textContent` 并写入剪贴板。

流式过程中每帧只更新格式化 HTML，不执行 Highlight.js；高亮和复制按钮在最终化时补上。这避免了逐帧重复语法高亮。

## 流式渲染

### 主聊天 `StreamingProcessor`

首次收到流时，`onStartStreaming()` 会通过 `saveReply(..., fromStreaming: true)` 创建或更新标准消息，所以流式消息从一开始就使用普通 `.mes` 骨架。

每个 generator yield 提供累计 `text`、候选 swipes、logprobs、tool calls 和 state。处理过程为：

- 每个 yield 立即更新内存中的累计结果。
- 每次发送 `STREAM_TOKEN_RECEIVED`；其参数实际上是当前累计 `text`，不一定是单个 token delta。
- `Stopwatch(1000 / streaming_fps)` 控制昂贵 DOM 更新频率，默认 30 FPS。
- `cleanUpMessage()` 清理停止词和不完整句子。
- 未结束时临时补齐奇数个星号、双引号、三反引号或三个波浪号，降低残缺 Markdown 造成的布局跳变。
- 更新 `chat[messageId]`，再对累计全文执行完整 `messageFormatting()`。
- 直接覆盖 `.mes_text.innerHTML`，或使用可选 fade-in 差量动画。
- reasoning 由 `ReasoningHandler` 同步更新到独立区域。

这个实现简单且保证与非流式格式一致，但复杂度随消息增长：每个可见帧都会重新 regex、Markdown parse、DOMPurify 并替换整段正文 DOM。长回复中的表格、大量 HTML 或代码块会逐渐变贵；选择文本、正文内部临时 DOM 状态也可能在下一帧丢失。

### 流式收尾

`finalizeIntermediaryMessage()` 会：

- 用 `isFinal = true` 再更新一次正文。
- 执行代码高亮和复制按钮。
- 完成 reasoning。
- 整理 swipes、logprobs 和 reasoning signature。
- 处理图片附件并刷新媒体。
- 发出 `MESSAGE_RECEIVED` 和 `CHARACTER_MESSAGE_RENDERED`。
- 更新 swipe 计数。

最终 `onFinishStreaming()` 再处理 auto-swipe、保存聊天和消息声音。

### 浮层 `StreamingDisplay`

`public/scripts/streaming-display.js` 动态创建一个可停止、最小化、关闭的浮层，放入最上层 open dialog 或 `document.body`。reasoning 和正文同样以累计全文调用 `messageFormatting()`，但它不参与主 `chat` 消息生命周期。

## 扩展边界

消息 UI 通过全局事件总线对扩展开放。关键事件包括：

- `MESSAGE_SENT`
- `USER_MESSAGE_RENDERED`
- `MESSAGE_RECEIVED`
- `CHARACTER_MESSAGE_RENDERED`
- `MESSAGE_UPDATED`
- `MESSAGE_EDITED`
- `MORE_MESSAGES_LOADED`
- `STREAM_TOKEN_RECEIVED`
- `STREAM_REASONING_DONE`

非流式 assistant 消息通常先触发 `MESSAGE_RECEIVED`，再装配 DOM，最后触发 `CHARACTER_MESSAGE_RENDERED`；流式消息把前两个 rendered 事件都留到现有 DOM 完成最终化之后。user 消息则有对应的 `MESSAGE_SENT` 和 `USER_MESSAGE_RENDERED`。

Translate、TTS、memory、quick reply、logprobs 等扩展依靠这些事件运行。扩展既可以调用公开的 `addOneMessage()` / `updateMessageBlock()`，也可以在 rendered event 后直接操作消息 DOM。因此，核心 renderer 提交 DOM 后，扩展仍可能追加 UI 或再次触发局部重渲染。

## 性能与生命周期

现有性能策略：

- 历史默认只显示最后 100 条。
- 历史消息先在内存中全部创建，再一次性 append。
- 加载更早历史时保持原视口位置。
- 流式 DOM 刷新默认限制到 30 FPS。
- 流式代码高亮延迟到最终化。
- 媒体加载不阻塞消息主体，并单独修正滚动。
- swipe 更新复用原消息节点，保留外围 listener。

主要限制：

- 没有虚拟列表；已加载消息全部常驻 DOM。
- 历史渲染对每条消息同步执行 regex、Showdown、DOMPurify 和 reasoning 初始化。
- 流式渲染反复处理并替换累计全文，不维护稳定块或增量 AST。
- `appendMediaToMessage()` 自身包含异步 DOM 更新，但 API 不可 await，代码中已有对应 TODO。

## 安全边界与风险

### 1. 消息 CSS 仍运行在主文档

风险级别：中高。

模型或角色卡输出的 `<style>` 会在 DOMPurify 后恢复成真实 style 标签。parser 会作用域化 selector、改写 class、移除 `@import`，并在默认禁止外媒时过滤包含 `://` 的值，但仍应把它看作防御性重写，不是隔离。

需要重点回归：

- `url(//host/path)`、转义 URL、data URL 和其他非 `://` 资源形式。
- `@font-face`、复杂嵌套 at-rule、伪类嵌套和 CSS parser error recovery。
- 可影响布局、遮挡或交互的 fixed/absolute、超大尺寸、pointer-events 等声明。
- selector 重写在 `:has()`、`:is()`、`:not()` 等复杂组合下是否始终限制在当前正文。

更强的安全边界是 Shadow DOM 或无 `allow-same-origin` 的 sandbox iframe；若保留主文档样式能力，则应建立针对 CSS escape 和跨消息影响的专门测试集。

### 2. CSP 被关闭

风险级别：中。

Helmet 未启用 CSP，意味着 DOMPurify 或后续扩展一旦出现旁路，浏览器层没有 CSP 兜底。由于 SillyTavern 需要广泛的扩展和自定义内容能力，直接启用严格 CSP 会有兼容成本，但至少可以评估 nonce/hash、`object-src 'none'`、`base-uri 'none'` 等可逐步采用的策略。

### 3. 结构化媒体绕过正文外链策略

风险级别：中低，取决于 `extra.media` 的来源可信度。

消息 HTML 内的外链媒体默认受 hook 限制，但 `appendMediaToMessage()` 直接把 `extra.media[].url` 写入 `src`。若扩展、导入聊天或第三方响应可以注入该字段，就可能在未显式允许外链媒体时发起网络请求。应明确这是产品有意允许的附件信任边界，还是需要复用 `isExternalMediaAllowed()`。

### 4. 完整与局部重渲染的空覆盖不一致

风险级别：低。

`display_text || mes` 与 `display_text ?? mes` 对空字符串解释不同，可能导致刷新前后正文出现差异。建议统一“空字符串是否为有效覆盖”的契约并增加回归测试。

### 5. 核心渲染缺少直接测试

本次在 `tests` 中未找到针对 `messageFormatting()`、CSS encode/decode、DOMPurify 消息 hook、`updateMessageElement()` 或流式/最终一致性的直接测试。当前最复杂且安全敏感的逻辑主要依赖运行时人工验证。

优先测试项应包括：

- Markdown + 原始 HTML + 恶意属性的净化快照。
- class 重写与 CSS selector 重写的一致性。
- CSS URL 和 at-rule 绕过样例。
- 外链媒体全局/角色覆盖设置。
- 不完整代码围栏和 emphasis 的流式过程。
- `display_text: ''`、reasoning、swipe 和局部更新一致性。
- 长消息下的每帧耗时及 DOM 状态保留。

## 适合复用的设计

在其他聊天应用中可复用以下做法：

- 全部正文路径共用一个格式化函数，避免历史、非流式和流式语义分叉。
- reasoning 与媒体采用结构化字段和专用容器，不在普通 Markdown 中硬解析。
- 正文 HTML class 与 CSS selector 同步改名并作用域化。
- 代码高亮延迟到流结束，避免高频重型后处理。
- rendered event 放在 DOM 可用之后，为扩展提供稳定时点。
- 媒体更新保留播放状态和滚动位置。

不宜直接照搬的是：

- 每帧重新解析和替换累计全文。
- 把模型 CSS 放在主文档，仅依赖自定义 selector 重写。
- 数据、格式化、DOM 装配和生成生命周期大量集中在 `public/script.js`。
- 依赖 DOM 属性和全局数组 index 作为消息身份；插入、删除和分支操作需要持续重编号与同步。

## 关键文件索引

| 文件 | 关键职责 |
|---|---|
| `public/script.js` | 主消息渲染、正文格式化、历史显示、流式处理、生成收尾 |
| `public/index.html` | `.mes`、reasoning、媒体和文件的静态模板 |
| `public/global.d.ts` | `ChatMessage` 与 `extra` 的渲染字段契约 |
| `public/scripts/chats.js` | CSS encode/decode、DOMPurify hook、媒体权限和聊天工具 |
| `public/scripts/reasoning.js` | reasoning 状态、提取、持久化和 DOM 更新 |
| `public/scripts/streaming-display.js` | 非主聊天场景的浮层式流式显示 |
| `public/scripts/sse-stream.js` | SSE 读取与可选 smooth streaming 节奏 |
| `public/scripts/tool-calling.js` | 工具调用解析、执行和 `tool_invocations` 记录 |
| `public/scripts/events.js` | 消息生命周期事件名 |
| `public/scripts/power-user.js` | 截断、流式 FPS、HTML 标签、外媒等渲染设置 |
| `src/server-main.js` | Helmet 与 CSP 状态 |

## 关键位置

- Markdown converter：`public/script.js:520`
- 消息模板引用：`public/script.js:447`
- 历史打印：`public/script.js:1475`
- 历史批量重显：`public/script.js:1497`
- 正文格式化：`public/script.js:1753`
- 局部消息更新：`public/script.js:1974`
- 媒体装配：`public/script.js:2157`
- 代码高亮与复制：`public/script.js:2420`
- 正文覆盖选择：`public/script.js:2464`
- 单条消息入口：`public/script.js:2492`
- 单条消息装配：`public/script.js:2559`
- 主聊天流处理器：`public/script.js:3481`
- assistant 消息写入：`public/script.js:6583`
- CSS encode/decode：`public/scripts/chats.js:536`、`public/scripts/chats.js:551`
- DOMPurify hook：`public/scripts/chats.js:1901`
- reasoning DOM 更新：`public/scripts/reasoning.js:542`
- 消息 HTML 模板：`public/index.html:7378`
- CSP 关闭：`src/server-main.js:104`

## 结论

SillyTavern 以字符串消息模型、统一富文本格式化、结构化旁路内容和命令式 DOM 生命周期组织消息渲染。它兼容角色卡 HTML/CSS、正则脚本、swipe、reasoning、媒体和扩展事件，主链也相对容易追踪。

其技术债集中在两个方向：一是 `public/script.js` 承担过多职责，渲染状态依赖全局数组和 DOM；二是流式累计全文重渲染与主文档 CSS 能力分别带来性能上限和安全复杂度。若要演进，优先级应是为净化/CSS 建立测试边界，其次再考虑把消息装配、正文 pipeline 和流式 renderer 拆成可独立验证的模块。
