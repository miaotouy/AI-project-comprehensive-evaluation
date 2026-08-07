# VCPChat 消息渲染器调查笔记

> 调查对象：`E:\works\git\VCPChat`
>
> 调查更新日期：2026-07-29
>
> 代码快照：`3f14e938e700a5487ca13c4a6d8a6caad8e70ac9`（分支：`main`）
>
> 调查方式：只读源码梳理，未修改目标仓库
>
> 调查范围：主聊天、群聊与语音聊天共用的消息渲染链；论坛、备忘录和独立文本查看器仅用于确认边界
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPChat 在 Electron renderer 进程内依次解释消息协议、更新流式 DOM，并运行富内容；Markdown 位于这条链路的中间层。

它同时处理五类问题：

1. 将 `role/content/id/context` 等消息数据装配成聊天气泡。
2. 在 Markdown 解析前识别 VCP 私有语法，并用保护、转换、恢复三个阶段解决语法互相吞噬的问题。
3. 将流式文本拆成已经稳定的前缀和仍会变化的尾部，以不同成本更新 DOM。
4. 在 HTML 进入 DOM 后补做 KaTeX、代码高亮、Mermaid、附件、交互按钮和 HTML 预览。
5. 运行消息内的 CSS、脚本、动画和 Three.js，并在消息离开视口或被替换时管理资源。

各层的交接规则决定了这套实现的行为：原始消息文本是最终数据源；预处理后的 Markdown 是协议解释结果；Marked 输出是尚未增强的中间 HTML；最终 DOM 还包含大量无法从 HTML 字符串直接恢复的运行时状态。

VCPChat 有三个值得关注的设计点：

- **有序占位转换隔离多层协议**：工具结果在外层 Marked 完成之前始终保持为 HTML 注释占位符；`contentPipeline.js` 的保护映射把 VCP 私有语法、LaTeX 和代码围栏拆成互不干扰的词法岛，避免任意返回内容破坏宿主消息结构。
- **稳定区/尾区 + morphdom**：稳定前缀完整处理一次后永久固化，只对不稳定尾部使用 morphdom 增量更新；长回复中已生成的 Mermaid、动画和工具块不会反复初始化。
- **富消息运行时**：助手 HTML 可在主聊天文档中展示内容、应用 scoped CSS 并执行脚本；这是 VCPChat 支持 Three.js、Anime.js 等交互能力的架构基础，详见"HTML 渲染方式"一节。

## 1. 系统位置与边界

### 1.1 依赖装载

`main.html` 直接装载以下浏览器端库：

| 能力 | 库 | 在渲染链中的位置 |
|---|---|---|
| Markdown | Marked | 文本预处理之后，DOM 后处理之前 |
| 数学 | KaTeX + auto-render | HTML 注入 DOM 后 |
| 代码高亮 | Highlight.js | HTML 注入 DOM 后；流式未闭合代码另有轻量路径 |
| 图表 | Mermaid | 完整 DOM 后处理阶段 |
| DOM diff | morphdom | 只更新流式消息的不稳定尾部 |
| 动画 | Anime.js | 消息脚本运行时与可见性管理 |
| 3D | Three.js | 消息脚本运行时与 WebGL 资源管理 |

主窗口在 `renderer.js` 中创建独立的 `Marked` 实例，并把它与 DOM、历史引用、设置引用和 Electron API 一并注入 `initializeMessageRenderer()`。`messageRenderer.js` 再把所需能力下传给 `contentProcessor.js`、`streamManager.js`、上下文菜单和其他子模块。

这是一种手工依赖注入：模块并不拥有聊天状态，而是通过形如 `{ get, set }` 的 ref 读取 `currentChatHistory`、`currentSelectedItem`、`currentTopicId` 和 `globalSettings`。因此同一套消息渲染器能够被主聊天和语音聊天用不同状态源初始化。

### 1.2 共用与非共用表面

主聊天和群聊共用 `modules/messageRenderer.js`；群聊通过 `Groupmodules/grouprenderer.js` 改写当前群组、话题和头像上下文。语音聊天窗口也单独装载同一个模块，并在 `Voicechatmodules/voicechat.js` 中注入自己的历史与 Marked 实例。

论坛、备忘录和 `modules/text-viewer.js` 并不完整复用这条主链。它们各自保留了 Marked、KaTeX、Mermaid 或工具块处理代码。本文所称的“VCPChat 消息渲染器”特指聊天气泡链路；相同语法在独立查看器和论坛中可能表现不同。

### 1.3 模块分层

```text
renderer.js
  事件入口、当前视图判定、依赖注入
        |
        v
messageRenderer.js
  单条消息总编排、协议级转换、Markdown、历史批处理
        |
        +--> contentPipeline.js
        |      Markdown 前的有序转换
        |
        +--> domBuilder.js
        |      消息外壳
        |
        +--> contentProcessor.js
        |      DOM 后处理、预览、CSS selector 作用域
        |
        +--> streamManager.js
        |      流式状态、稳定区/尾区、最终化与落盘
        |
        +--> animation.js
        |      消息脚本、动画和 Three.js
        |
        +--> visibilityOptimizer.js
               视口外暂停、延迟重型激活与资源登记
```

`messageRenderer.js` 仍是事实上的中心：当前约 3,748 行，既包含协议识别，也包含消息外观、缓存、附件、历史批处理和生命周期协调。其子模块已经形成分层，但还不是一个完全解耦的 renderer core。

## 2. 消息数据与上下文

### 2.1 消息对象

主链没有集中定义的 `Message` 类型，渲染函数按约定读取对象字段。常见字段如下：

| 字段 | 用途 |
|---|---|
| `id` | DOM `data-message-id`、流式状态表和历史定位键；缺失时现场生成 |
| `role` | 区分 `user`、`assistant`、`system`，决定文本预处理、头像和 CSS scope |
| `content` | 通常是字符串；也兼容 `{ text }`，空值与异常对象有降级分支 |
| `timestamp` | 时间显示和临时 ID 来源 |
| `name` | 群聊 Agent 或系统发送者名称 |
| `agentId` | 群聊 Agent 身份、颜色和上下文关联 |
| `avatarUrl` / `avatarColor` | 群聊或流消息的即时头像元数据 |
| `isGroupMessage` / `groupId` / `topicId` | 决定历史属于哪个会话，以及流事件是否对应当前视图 |
| `isThinking` | 选择思考占位 DOM，而不是正常正文渲染 |
| `attachments` | 正文后追加的附件数据 |
| `finishReason` | 流最终化时写回历史 |

消息身份同时存在于数据层和 DOM 层：历史数组以 `id` 查找消息，流管理器也以同一 `id` 维护队列和上下文，页面则用 `.message-item[data-message-id="..."]` 定位气泡。这个 ID 是三个层面的连接点。

### 2.2 流上下文

流事件还携带独立的 `context`：

```text
agentId / groupId
topicId
isGroupMessage
agentName
avatarUrl / avatarColor
```

`renderer.js` 用它判断消息是否属于当前可见的 Agent/群组和话题；`streamManager.js` 则把它保存在 `messageContextMap` 中，用来定位后台会话历史。因而“是否画 DOM”和“是否更新数据”是两件事：不可见会话可以不创建气泡，但仍要初始化占位消息、累积流文本并保存历史。

### 2.3 对话深度不是数组索引

前端正则规则可以按消息深度生效。这里的深度按 user/assistant 对话轮次计算，而不是简单使用数组下标。历史批量渲染前，`buildTurnDepthMap()` 一次性生成 `messageId -> depth`；实时消息不在历史中时才临时拼入消息后计算。

因此前端正则处于完整消息层：它需要 `role` 和轮次深度，且只对最终完整文本运行，不参与逐 chunk 转换。

## 3. 入口与事件分派

### 3.1 非流式入口

普通用户消息、历史消息、系统消息和部分群聊消息直接调用：

```text
renderMessage(message)
  -> createMessageSkeleton()
  -> 角色相关文本准备
  -> 计算轮次深度并应用前端正则
  -> renderMarkdownToHtml()
  -> 写入基础 HTML
  -> renderPostProcessedHtml()
```

`renderFullMessage()` 和 `updateMessageContent()` 是已有气泡的完整替换入口。它们最终也回到同一套 Markdown 与 DOM 后处理能力，而不是只做字符串追加。

### 3.2 VCP 统一流事件

`renderer.js` 监听 `vcp-stream-event`，主要事件及去向如下：

| 事件 | 行为 |
|---|---|
| `agent_thinking` | 以“思考中”消息启动流状态 |
| `start` | 确保流消息已初始化；重复 start 由状态检查吸收 |
| `data` | 交给 `appendStreamChunk()` 解析 chunk 并排队 |
| `end` | `finalizeStreamedMessage()`，随后用真实落盘文本触发 Flowlock 后续逻辑 |
| `error` | 合并已收文本与错误说明，再走同一最终化流程 |
| `full_response` | 使用 `renderFullMessage()` 更新历史及完整 DOM |
| `remove_message` | 当前视图中移除对应消息及其资源 |

事件分发层只判断当前视图是否需要 UI 行为，流管理器仍负责后台会话的数据一致性。`end` 之后 Flowlock 读取的是 `finalizeStreamedMessage()` 返回的最终内容，而不是假设事件一定携带完整 `fullResponse`。

## 4. 单条完整消息的渲染过程

### 4.1 消息骨架

`domBuilder.createMessageSkeleton()` 创建稳定的结构层：

```html
<div class="message-item ..." data-message-id="...">
  <div class="message-avatar-container">...</div>
  <div class="message-content-wrapper">
    <div class="name-time-block">...</div>
    <div class="md-content"></div>
  </div>
</div>
```

角色、群聊身份、用户气泡布局和思考状态体现在 class 与 data attribute 上。骨架本身不解析内容；正文始终进入 `.md-content`。

每条 assistant 消息还会获得唯一 DOM `id`。后续 scoped CSS 以这个 ID 为根重写 selector，并在 `document.head` 中插入对应样式节点。

### 4.2 角色相关准备

在通用 Markdown 流水线之前，user 与 assistant 走不同准备逻辑：

- user 文本经 `prepareUserMessageText()` 处理用户侧展示格式。
- assistant 文本经 `processAssistantScopedHtmlContent()` 提取 `<style>`、改写 CSS selector，并处理需要 scope 的结构化 HTML。
- 然后才计算消息深度并应用 Agent 配置中的前端正则。

这说明 CSS scope 不属于 Marked 插件，而是更早发生的 assistant 内容变换；前端正则也不是 Markdown AST 插件，而是完整字符串上的规则系统。

### 4.3 Markdown 前处理的顺序协议

`contentPipeline.js` 把完整渲染固定为以下顺序：

| 顺序 | step | 目的 |
|---:|---|---|
| 1 | `strip-persona-backfill-tail` | assistant 消息移除 Persona 回填注释；使用 JSON 括号配平而不是贪婪删到末尾 |
| 2 | `normalize-emoticon-urls` | 修复表情包 URL |
| 3 | `protect-tool-results` | 将工具结果整体替换为 HTML 注释占位符 |
| 4 | `protect-tool-requests` | 保护工具请求，并只在请求内部解释“始/末”字段标记 |
| 5 | `transform-mermaid-placeholders` | 把特殊 Mermaid 表达改为后续可识别形式 |
| 6 | `protect-code-blocks` | 暂存代码围栏，避免结构修正污染代码 |
| 7 | `transform-flowlock-blocks` | 仅对 assistant、且在工具与代码内容被保护时识别 Flowlock |
| 8 | 三类 de-indent | 修复被缩进误判的代码、HTML 和工具请求结构 |
| 9 | `transform-desktop-push` | 完整块或半截块转成状态占位卡 |
| 10 | `restore-tool-requests` | 恢复请求，准备变成工具调用 UI |
| 11 | `transform-special-blocks` | 处理工具请求、思考链、DailyNote、按钮、角色分隔符等 |
| 12 | `ensure-html-fenced` | 识别完整 HTML 文档的代码展示边界 |
| 13 | `apply-common-content-processors` | 通用文本结构修正 |
| 14 | `normalize-adjacent-bold-boundaries` | 修复中文/引号无空格相邻时的 CommonMark 粗体边界 |
| 15 | `restore-code-blocks` | 最后恢复代码围栏 |

该流水线的输出不只有文本，还带 `state.toolResultMap` 等中间状态。工具结果特意不在此处恢复，而要穿过 Marked 后再生成独立 HTML。

这种设计解决的是“多种文本语言叠加”问题。工具返回内容可能包含代码围栏、协议结束标记、HTML 和 Markdown 表格；若各转换器直接在同一个字符串上依次做正则替换，后面的规则会把前一层载荷误当成宿主语法。保护映射相当于为各语言临时划定词法岛。

### 4.4 LaTeX 保护是第二层词法岛

完整预处理之后、Marked 之前，`protectLatexBlocks()` 再保护数学表达式。其处理比简单的 `\$...\$` 正则复杂：

- 先用逐行状态机暂存代码围栏，避免代码中的 `$` 和 `$$` 跨块匹配。
- 块公式只接受独占行的 `$$...$$`、`\[...\]` 形式。
- 行内 `\(...\)` 直接保护。
- 单美元公式需经过启发式判断，排除价格、路径、模板表达式、跨表格列内容和超长/跨行候选。
- HTML 标签被视为硬边界，不能跨两个元素配对美元符号。
- 被认可的 `$...$` 会转换为 `\(...\)`，再交给 DOM 后的 KaTeX auto-render。

Marked 完成后，LaTeX 占位符以一次正则扫描恢复。这里保护的目标不是隐藏内容，而是防止 Markdown 把反斜杠、下划线等 TeX 语法改写。

### 4.5 Marked 与 HTML 缓存

主窗口的 Marked 设置启用 GFM、表格和换行，并允许原始 HTML 通过。源码传入了 `sanitize: false`；在当前 Marked 版本中，更准确的事实是：渲染链没有安装 HTML sanitizer，原始 HTML 会进入输出。

完整转换为：

```text
原始文本
  -> full-render pipeline
  -> LaTeX 占位
  -> marked.parse()
  -> 恢复 LaTeX
  -> 恢复并独立渲染工具结果
  -> raw HTML
```

`renderMarkdownToHtml()` 对这段 raw HTML 做 LRU 风格缓存：

- 最多 500 项、约 20 MiB。
- 单项 raw HTML 上限约 1 MiB。
- 原文短于 512 字符或长于 512 KiB 时跳过。
- cache key 包含 pipeline 版本、role、轮次深度、相关设置指纹、文本长度与 FNV-1a hash。
- assistant 文本含结构化 HTML、`<style>` 或内联样式时跳过，因为 CSS scope ID 和向 `head` 注入样式具有消息级副作用。

缓存的是“Markdown 到 raw HTML”的纯度较高部分，不缓存附件、KaTeX DOM、Mermaid SVG、脚本执行或事件监听器。

### 4.6 DOM 后处理

`renderPostProcessedHtml()` 是完整 DOM 的统一提交点。替换正文时按以下阶段运行：

1. 清理旧 iframe 预览、`window.message` 监听器、动画和 WebGL 资源。
2. 写入 raw HTML，并处理图片 URL 与加载状态。
3. 追加附件 DOM。
4. 若当前消息不在重型激活区，到此暂停并标记 `vcpHeavyPending`。
5. `processRenderedContent()` 执行 KaTeX、Highlight.js、代码复制、工具块美化、按钮和 HTML 预览等同步增强。
6. 异步执行 Mermaid。
7. 下一任务中用 TreeWalker 做标签、警告和引号等文本高亮，避免与前面 DOM 改写冲突。
8. 执行消息中的脚本与动画。

所以 `contentDiv.innerHTML = rawHtml` 不是渲染完成，只是基础 DOM 已出现。完整内容的可交互状态要等后处理阶段结束。

## 5. VCP 私有语法如何落到 UI

### 5.1 语法总览

| 输入形态 | 识别阶段 | 最终形态 |
|---|---|---|
| `<<<[TOOL_REQUEST]>>>...` | full-render 特殊块转换 | 工具调用 `<pre>`/结构化块 |
| `[[VCP调用结果信息汇总:...]]` | Marked 前保护、Marked 后恢复 | 独立工具结果卡片 |
| `<<<DailyNoteStart>>>...` | 特殊块转换 | 日记或日记更新结构 |
| VCP 元思考链 | 特殊块转换 | 可折叠/样式化思考区域 |
| `<think>` / `<thinking>` | 特殊块转换 | 常规思考区域 |
| Flowlock 控制块 | 工具与代码保护之后 | 状态说明/控制块 UI；最终控制逻辑另由 Flowlock manager 消费 |
| `DESKTOP_PUSH` | 完整与流式均有专门处理 | 聊天气泡中的推送状态卡 + 桌面画布 IPC |
| Mermaid fence | Markdown 前占位、DOM 后渲染 | Mermaid SVG 与缩放工具栏 |
| `[[点击按钮:...]]` | 特殊块转换 | 可点击 AI 操作按钮 |
| `{{VCPChatCanvas}}` | 特殊块转换 | 画布占位节点 |
| 原始 HTML / `<style>` / `<script>` | assistant HTML 准备与 DOM 后处理 | 主消息 DOM、scoped CSS、脚本运行时 |

### 5.2 工具请求

工具请求不能只依赖一个跨行正则，因为参数字段内部可能出现与协议相似的标记。`replaceToolRequestBlocks()` 从开始标记向后扫描：遇到“始/末”或 `ESCAPE` 字段时先跳过整个字段，再寻找真正的 `END_TOOL_REQUEST`。被反引号包裹的协议标记不算控制语法。

请求保护阶段会在请求内部执行 `processStartEndMarkers()`，但普通聊天正文不再全局扫描裸“始/末”。这减少了用户讲解协议本身时触发格式变化的可能。

恢复后的请求在 `transformSpecialBlocks()` 中变成专用 HTML，之后 `<pre>` 还会由 `contentProcessor` 根据工具类型美化。因此工具请求跨越了字符串协议层和 DOM 装饰层。

### 5.3 工具结果

工具结果采用最完整的隔离路径：

```text
完整工具结果原文
  -> <!--VCP_TOOL_RESULT_n-->
  -> 外层消息执行全部预处理和 Marked
  -> 在生成的 HTML 中找到占位注释
  -> renderToolResultBlock(原始工具结果)
  -> 卡片字段解析
  -> “返回内容”等字段独立执行收紧后的 Markdown
```

独立 Markdown 会先封装完整 HTML 文档，并转义代码围栏外的原始 HTML。它并不是与 assistant 正文完全相同的 HTML 运行时；工具返回被视为不应获得同等主页面能力的数据载荷。

返回内容的 JavaScript 字符串长度超过 50,000 时只展示前 80 行，完整值保存在内存映射中，展开时再读取。这里的阈值按 `value.length` 判断，并非严格的 UTF-8 字节数；截断只发生在工具字段展示层，不修改历史中的原始消息。

### 5.4 Mermaid

Mermaid 不是让 Marked 直接生成最终图。相关代码围栏先转换成 `.mermaid-placeholder`，源代码经编码放入 data attribute；DOM 后处理时再解码为 `.mermaid` 节点并调用 `mermaid.run()`。

成功后 SVG 被包进 viewer，附带缩小、重置、放大和适应宽度操作。失败时则保留错误说明与原始图代码。占位节点带有 preserve 属性，使 morphdom 不会在流式更新中破坏已经生成的 SVG 和交互状态。

### 5.5 Desktop Push

Desktop Push 同时是一种显示语法和流式副作用协议。

完整 Markdown 路径只把块转成“已推送到桌面画布”的状态卡。流式路径则在 chunk 级维护 `desktopPushStates`：识别开始标签、缓冲内容、二次验证内容前缀、创建 widget、定期 append，并在结束标记或长时间无新 token 时 finalize。

聊天累积文本仍保留完整开始/结束块，供最终渲染生成可解释的占位卡；桌面 IPC 的增量发送则由单独状态机完成。同一原始协议由此产生两个投影：聊天记录中的说明性 UI，以及桌面画布中的实际内容。

## 6. 流式渲染引擎

### 6.1 状态并不只有一个字符串

`streamManager.js` 当前约 2,384 行。每条流消息至少涉及以下状态表：

| 状态 | 含义 |
|---|---|
| `messageInitializationStatus` | `pending -> ready -> finalized` 生命周期 |
| `preBufferedChunks` | 初始化异步完成前先到达的数据块，最多保留最新 1000 个 |
| `pendingFinalizationEvents` | `end/error` 比初始化更早到达时暂存最终化事件 |
| `messageContextMap` | 消息属于哪个 Agent/群组/话题 |
| `viewContextCache` | 是否需要更新当前 DOM |
| `accumulatedStreamText` | 完整原始流文本，最终历史的数据候选 |
| `streamingChunkQueues` | 平滑播放时尚未消费的语义小块 |
| `streamSegmentStates` | 稳定截止点、已固化块、尾部文本等分段状态 |
| `messageDomCache` | 气泡与 `.md-content` 的直接引用 |
| `desktopPushStates` | Desktop Push 的独立增量协议状态 |

这些 map 让网络时序、历史保存、当前视图和动画播放可以分别推进，而不要求所有事件严格按 `start -> data -> end` 到达。

### 6.2 初始化与乱序吸收

`startStreamingMessage()` 先合成上下文并把状态设为 `pending`，再根据上下文取得正确历史：

- assistant chat 和 voice chat 使用当前内存历史。
- 当前可见的普通/群组话题也使用内存历史。
- 后台话题从持久化源重新读取历史。

只有当前视图会创建或复用气泡，后台会话只更新占位消息和历史。初始化完成后状态变成 `ready`，依次回放预缓冲 chunk；如果期间已收到 `end/error`，再异步重放 pending finalization。

这个状态转换专门防止两类竞态：chunk 先于异步历史读取完成，以及结束事件先于消息从 `pending` 进入 `ready`。

### 6.3 chunk 归一化与平滑队列

`appendStreamChunk()` 兼容多种 payload：

```text
choices[0].delta.content
delta.content
content
原始字符串
无 error 的 raw
```

JSON parse error chunk 会被丢弃。有效文本先经过 Desktop Push 拦截器，同时完整原文追加进 `accumulatedStreamText`。

启用平滑流式时，较长 chunk 会按中文连续段、英文数字段、标点和空白拆成小语义单位，每个单位最多约 10 个字符。队列越深，每帧消费越多；消息已最终化但队列未清空时会加速追平，避免最后剩余内容一次跳出。

所有活动消息共用一个 `requestAnimationFrame` 循环，并限制为约 30 FPS。即使关闭平滑播放，也不是每个网络 chunk 立刻独立改 DOM，而是标脏后由全局帧循环合并更新。

### 6.4 稳定前缀与可变尾部

每个流式 `.md-content` 内会建立两个逻辑区域：

```html
<div class="vcp-stream-stable-root">
  <div class="vcp-stream-stable-blocks">...</div>
</div>
<div class="vcp-stream-tail-root">...</div>
```

`findExplicitStablePrefix()` 扫描原始文本，寻找可以永久固化的边界。它理解的不只是空行，还包括：

- 已闭合代码围栏。
- 独占行的块数学。
- 已闭合思考链和 `<think>`。
- HTML 注释、`<style>`、`<script>` 及裸 `<div>` 动画岛。
- VCP 需要成对结束的特殊块。
- 普通段落边界，并故意保留最后一个安全段在尾部。

新稳定范围只解析和追加一次，并可立即执行完整后处理；之后不再参与每帧重建。剩余尾部使用 `stream-fast` 预处理和专门的 `parseStreamTailMarkdown()`。

这种分段比“整条消息每帧 Marked + innerHTML”更重要：长回复的成本主要落在仍有歧义的最后一小段，已完成表格、图表、按钮或动画不会反复初始化。

### 6.5 尾部 morphdom

尾部每帧重新得到目标 HTML，但通过 morphdom 只修改差异。节点 key 来自 `id`、`data-vcp-key` 或 `data-vcp-block-key`。更新钩子还会保留：

- 已完成后处理或声明 preserve 的复杂块子树。
- 按钮 disabled 与完成标记。
- 正在播放的 video/audio。
- 当前输入焦点。
- 已加载图片及其事件状态。
- 流式淡入和扫光动画 class。

若残缺 HTML 使 morphdom 抛错，该帧会被忽略，等待下个 chunk 让结构闭合。没有 morphdom 时才退化为尾区 `innerHTML` 覆盖。

### 6.6 未闭合代码围栏

流尾若含未闭合代码 fence，不完全依赖 Marked 的容错输出。`parseStreamTailMarkdown()` 把围栏前缀正常解析，把未闭合部分生成稳定的逐行代码 DOM；完成的行带 key，可被 morphdom 复用，并按行执行轻量 Highlight.js 与扫光动画。

这解决了常见的流式代码闪烁：新增一行时不必替换整个 `<pre><code>`，已有行也不会重复高亮。最终 fence 闭合或消息结束后，完整渲染仍会重新生成权威代码块。

### 6.7 最终化与权威文本

`finalizeStreamedMessage()` 先标记 `finalized`，然后重新读取该上下文的最新历史。最终文本在两个候选中选择：

- renderer 端累计的 `accumulatedStreamText`。
- 结束 payload 中的 `fullResponse`。

当 payload 更长或包含错误恢复警告时优先使用 payload；若两者都只是思考占位，则转为空文本或系统错误。

选定文本先写回历史消息，再对当前视图执行一次完整流程：移除 stable/tail 临时根，应用完整前端正则与轮次深度，运行 full-render pipeline、Marked 和全部 DOM 后处理。最后保存历史，并清理队列、累积文本、分段与 Desktop Push 状态；DOM/context cache 延迟约 5 秒释放。

因此流式 DOM 不是数据源，甚至也不是最终 HTML 的增量延续。它是对当前原文的临时投影，最终事件会用完整消息重新解释一次全部协议。

## 7. HTML 渲染方式

HTML 在 VCPChat 中有三种承载形式，渲染方式不同：

| 来源 | 运行位置 | 特征 |
|---|---|---|
| assistant 正文中的原始 HTML | 主聊天文档 `.md-content` | 可与 Markdown 混排，可提取样式和脚本 |
| fenced HTML 代码块的预览 | 动态 iframe `srcdoc` | 用户点击预览，具有 iframe 生命周期和消息通信 |
| 工具结果中的 HTML | 收紧后的工具结果 Markdown | 代码围栏外的原始 HTML 被封装或转义 |

第一种是"消息即页面片段"，第二种是"代码工件预览"，第三种是"外部数据展示"。

### CSS scope

assistant 文本含结构化 HTML、`<style>` 或 `style=` 时，消息获得唯一 scope ID。`<style>` 内容被提取并写入 `document.head`；`contentProcessor.scopeCss()` 将 selector 改写到消息根下。样式因此仍处于同一 document 的 cascade 中，作用域依靠自定义字符串解析改写；scoped style 节点在消息删除、更新或清空聊天时单独移除。渲染缓存遇到此类内容会旁路，因为 scope ID 和 `head` 副作用不能复用。

### 脚本执行

`animation.processAnimationsInContent()` 会收集消息中的 `<script>`：外部 `src` 通过动态 script 元素加载；内联脚本被重新执行；常见 Three.js、Anime.js CDN URL 会改写到本地 vendor 文件；`requestAnimationFrame`、`setTimeout`、`setInterval` 被包装成可登记、可暂停的版本；`document.write/open/close` 被拦截；Anime.js 实例、Three.js renderer 和动画句柄登记到所属消息，用于资源回收。

主窗口配置了 `contextIsolation: true` 和 `nodeIntegration: false`，消息脚本不能直接 `require()` Node 模块；脚本仍运行在聊天 renderer 的页面上下文，可以访问同源 DOM 和页面全局对象。

## 8. 历史渲染、性能与生命周期

### 8.1 历史不是虚拟列表

`renderHistory()` 默认先渲染最新 5 条，再以每批 10 条、批间约 100 ms 的方式从近到远补旧消息。首批并行创建，使用 `DocumentFragment` 一次插入；旧批次优先在 `requestIdleCallback` 中插到列表顶部。

这改善了首屏时间，但最终仍会把全部历史消息保留在 DOM 中。它是渐进装载，不是窗口化虚拟列表。

### 8.2 render session

每次历史切换会递增 render session。异步附件、Mermaid、批次插入和延迟高亮在提交前检查 session 与节点连接状态。旧会话的异步任务即使稍后完成，也不应写进新会话 DOM。

该机制是聊天切换一致性的核心，和 AbortController 不同：它不一定取消底层工作，而是在提交点拒绝过期结果。

### 8.3 延迟重型增强

旧历史消息即使基础 HTML 已插入，也可以将 KaTeX、Mermaid、脚本等重型步骤标记为 pending。`visibilityOptimizer.isMessageInHotZone()` 以滚动容器上下约 200 px 为热区；进入热区后再调用消息保存的 `_vcp_activateHeavy()`。

这里存在两层“可见性优化”：

1. 尚未执行重型后处理的历史消息，接近视口时才激活。
2. 已运行的动画消息离开视口后暂停，回来时恢复。

### 8.4 动态资源登记与回收

`visibilityOptimizer` 为每个消息节点保存：Anime.js 实例、Three.js context、Web Animations、Canvas/rAF、媒体、SVG、GIF/WebP、可暂停 timer 和 MutationObserver。它还会拦截 `Element.prototype.animate`，把后创建的 Web Animation 归属到最近的 `.message-item`。

消息更新或删除时，资源清理链包括：

- iframe 预览的显式 cleanup 与 message listener 移除。
- timer、rAF、Anime.js 动画停止。
- Three.js renderer dispose。
- Web Animations cancel。
- IntersectionObserver 与 MutationObserver 解绑。
- scoped style 节点删除。

这也解释了为什么正文替换不能只设置一次 `innerHTML`：旧子树上的浏览器资源和模块外状态不会随 DOM 字符串自动释放。

## 9. 实现中的关键取舍

### 9.1 字符串转换优先于 AST

VCPChat 没有为 VCP 语法建立统一 AST，而是在 Marked 前通过有序字符串转换和占位映射构造 Markdown。优势是容易兼容模型输出中的非严格格式，也可以在现有 Marked 上逐步叠加协议。

代价是顺序本身成为隐式 grammar：任何新规则都必须知道工具结果、工具请求、代码、LaTeX、HTML 和流式残缺块何时已被保护。`contentPipeline.js` 的价值主要是把这套顺序从散落调用提升为显式协议，而不是消除字符串处理。

### 9.2 完整渲染与流式渲染接受短暂不一致

`stream-fast` 只做 Persona 尾部剥离、表情 URL、缩进修正、通用处理和粗体边界等轻量幂等变换。复杂 VCP 块在流中可能暂时显示为普通文本、半成品卡片或保守尾区。

系统不要求每一个 token 时刻都与最终 DOM 等价，而是保证结束后完整重放得到权威结果。这是一种明确的性能取舍：流中优先稳定与低开销，收尾时优先语义完整性。

### 9.3 “稳定区”进一步缩小单次更新范围

30 FPS 和 chunk 合帧只能减少更新次数；稳定前缀则减少每次更新所覆盖的数据量。对长消息而言，后者将潜在的“文本长度 × 帧数”重复解析，收敛为“每个稳定块完整处理一次 + 小尾部多次 diff”。

它同时保护运行时状态：已经生成的 Mermaid、按钮、媒体和动画岛可以离开 morphdom 的变化区域，不必依赖越来越复杂的 diff preserve 规则。

### 9.4 富消息能力与运行时治理

原始 HTML、CSS、脚本、Canvas 和 Three.js 让模型输出具备交互能力。消息因而接近在宿主页面执行的小应用，需要对应的运行时治理。

CSS scope、timer 包装和视口暂停解决的是互相干扰、性能与资源回收，不改变代码运行的宿主上下文。

## 10. 测试与可验证性现状

`package.json` 没有测试脚本，也未发现直接覆盖主消息渲染链的自动化测试。源码中的保障主要来自：

- pipeline step 的显式顺序与大量边界注释。
- 保护映射和 role/depth/cache version 等运行时约束。
- morphdom 异常回退与多处连接状态检查。
- render session、pending finalization 和延迟 cleanup 等竞态防线。
- 控制台 debug/warn 日志。

从可验证性角度看，这套系统至少包含四种不同输出层，单看最终截图无法定位是哪层出错：

```text
原始消息
  -> full-render 预处理文本及占位映射
  -> Marked raw HTML
  -> DOM 后处理结果
  -> 脚本运行后的动态状态
```

流式链还多出初始化状态、累计原文、稳定截止点、尾部目标 HTML和最终权威文本。当前实现允许通过函数边界和 `stepsApplied` 观察这些层，但仓库中没有把它们固化成回归样例。

## 11. 关键文件索引

| 文件 | 关键位置 | 调查价值 |
|---|---:|---|
| `renderer.js` | 约 436 | 初始化 `messageRenderer` 及 ref 注入 |
| `renderer.js` | 约 523-744 | VCP 流事件分派、当前视图判定、错误旁路 |
| `renderer.js` | 约 2371 | Marked 实例配置 |
| `modules/messageRenderer.js` | 约 65 | LaTeX 保护与单美元判断 |
| `modules/messageRenderer.js` | 约 308 | VCP 语法正则与工具请求扫描 |
| `modules/messageRenderer.js` | 约 1345 | assistant CSS/HTML scope |
| `modules/messageRenderer.js` | 约 1605 | full-render 与 stream-fast 入口 |
| `modules/messageRenderer.js` | 约 1735 | Markdown 转换与 HTML 缓存 |
| `modules/messageRenderer.js` | 约 1894 | 工具结果字段化渲染 |
| `modules/messageRenderer.js` | 约 2672 | 统一 DOM 后处理提交点 |
| `modules/messageRenderer.js` | 约 2743 | 单条消息总编排 |
| `modules/messageRenderer.js` | 约 3408 | 历史渐进批处理 |
| `modules/renderer/contentPipeline.js` | 约 308 | 完整流水线的顺序协议 |
| `modules/renderer/contentPipeline.js` | 约 370 | 流式轻量流水线 |
| `modules/renderer/streamManager.js` | 约 184 | 初始化、预缓冲与延迟最终化状态 |
| `modules/renderer/streamManager.js` | 约 920 | 稳定前缀扫描 |
| `modules/renderer/streamManager.js` | 约 1303 | stable/tail DOM 与 morphdom 更新 |
| `modules/renderer/streamManager.js` | 约 1556 | 流消息初始化与后台历史选择 |
| `modules/renderer/streamManager.js` | 约 1737 | 全局 30 FPS 渲染循环 |
| `modules/renderer/streamManager.js` | 约 2029 | chunk 归一化与排队 |
| `modules/renderer/streamManager.js` | 约 2122 | 最终文本选择、完整重渲染和清理 |
| `modules/renderer/contentProcessor.js` | 约 591 | `<pre>`、代码复制和 HTML preview |
| `modules/renderer/contentProcessor.js` | 约 1094 | KaTeX、Highlight.js 和按钮等后处理 |
| `modules/renderer/contentProcessor.js` | 约 1147 | CSS selector scope |
| `modules/renderer/animation.js` | 约 170 | 消息脚本加载与执行 |
| `modules/renderer/visibilityOptimizer.js` | 约 41 | IntersectionObserver 与全局动画拦截 |
| `modules/renderer/visibilityOptimizer.js` | 约 799 | 消息动态资源清理 |

## 结论

VCPChat 的消息渲染架构可以概括为：以原始消息字符串为事实源，以有序占位转换解释多层协议，以 Marked 生成基础结构，以 DOM 后处理补足富内容，再由流式分段和生命周期模块维持交互状态。

整体实现围绕“受保护的字符串阶段”和“带副作用的 DOM 阶段”展开。工具结果隔离、LaTeX 保护、稳定区/尾区和最终完整重放共同保证渲染正确性；scoped CSS、脚本执行和可见性资源管理则把职责扩展到了宿主运行时。
