# OpenOcta 消息渲染器调查笔记

> 调查对象：`https://github.com/openocta/openocta`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`0c7dac2284211facdfc813166fe648d093153bb6`（分支：`main`）
>
> 调查方式：只读源码静态梳理；逐段阅读 `ui/src/ui/chat` 的解析与渲染函数、Markdown 管线、A2UI 桥接、文件与附件承载组件及对应测试，未运行构建与浏览器
>
> 调查范围：消息从 `chat` 事件与历史接口进入可见 UI 的完整链路、列表与滚动、消息壳层、Markdown 与富文本、工具/推理/附件/A2UI 节点、HTML 与文件承载边界、交互反馈、性能与测试、扩展方式；Composer 与工作台结构留给 Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenOcta 的聊天渲染器是「宽松输入 + 分段拼装」型：它不消费固定的 part schema，而是接收 `unknown[]` 的历史消息与若干条实时字符串，用一组防御性提取函数把字符串、parts 数组、工具调用、推理块、A2UI 块、附件标记等异构形态归一，再按角色分组、按「文本段 / 工具段」切片，最后渲染成折叠面板加气泡。Markdown 管线很薄：`marked`（GFM）解析后交给 DOMPurify 白名单清洗，前置一步针对模型输出粘连问题的文本修复；代码块没有语法高亮，也没有数学公式与 Mermaid。真正有特色的两处是 A2UI 交互面板（Agent 返回结构化 surface，面板持有自己的 processor 并可回传动作）和「按路径回捞交付物」的附件发现机制。

关键实现事实：

- **输入无 schema**：消息可以是字符串、parts 数组或只带 text 字段的外壳，角色取值也超出常规的用户与助手两类；归一逻辑集中在 `ui/src/ui/chat/message-normalizer.ts` 与 `message-extract.ts`。
- **流式是整串拼接后重渲染**：每个 `delta` 直接把分片追加到 `chatStream`，没有批量合并或节流；聊天文本分片触发整线程重建与整段 Markdown 重新解析，只有工具流有 300ms 节流（对照 `ui/src/ui/app-tool-stream.ts:137-157`）。
- **完成态用服务端历史收口**：`final` 只是把最后一条替换进本地数组，随后 `chat.history` 全量重载，A2UI 块在收口前被并入助手消息，避免重载后消失。
- **助手消息被二次切片**：同一轮内的思考、工具、正文被拆成「思考过程」「工具运行」两个折叠面板与最终回答气泡，最后一个含可见内容的段才作为回答。
- **Markdown 只有白名单清洗**：解析后的 HTML 只保留排版类标签与少数属性，脚本、样式与内嵌框架标签都不在允许集合内，链接统一补 `noopener`，图片地址只接受内联图片与 http(s)，表格外层再包一层横向滚动容器；完整白名单见 `ui/src/ui/markdown.ts:81-111`。
- **内容承载分三档**：Markdown 文本进 `unsafeHTML`（清洗后）、A2UI 表面交给 `@a2ui/lit` 的组件目录渲染、HTML/PDF 预览用无 `sandbox` 的 `iframe`。
- **无虚拟化**：列表一次渲染最近 500 条，靠 keyed `repeat` 与滚动跟随处理更新。

## 总体渲染链路

```text
chat 事件 / chat.history
  -> state.chatMessages（历史）+ chatStream / chatReasoningStream（实时）+ chatA2UIMessages
  -> openocta-chat-thread.render()
       buildChatItems()            历史裁剪、工具消息合并、实时项插入
       groupMessages()             同角色连续消息合并为 MessageGroup
       repeat(items, key)          按 key 复用
  -> renderMessageGroup / renderStreamingGroup / renderA2UIGroup / renderReadingIndicatorGroup
  -> 助手组内 renderAssistantTurnMessages()
       segmentAssistantTurn()      按「文本段 / 工具段」切片
       renderThinkingProcessPanel + renderToolProcessPanel
       finalResponseSegment -> renderGroupedMessage -> toSanitizedMarkdownHtml -> unsafeHTML
  -> renderGroupedMessage()        图片、文件、思考、Markdown、A2UI、工具卡
```

## 1. 消息与内容块数据模型

渲染器没有自己的消息类型，只有一组渲染期结构（`ui/src/ui/types/chat-types.ts:6-56`）：

| 结构 | 字段 | 来源 |
|---|---|---|
| `ChatItem` | `message` / `stream` / `reading-indicator` / `a2ui` 四种 kind | `buildChatItems` 生成 |
| `MessageGroup` | `role`、`messages[]`、`timestamp`、`isStreaming` | 同角色连续消息合并 |
| `ToolCard` | `kind: call \| result`、`name`、`args`、`text` | 从消息 content 提取 |
| `NormalizedMessage` | `role`、`content[]`、`timestamp`、`id` | `normalizeMessage` 输出 |

消息对象本身是 `unknown`，实际接受三种外壳：`content` 为字符串、`content` 为 parts 数组、或只有顶层 `text` 字段。parts 数组中被识别的类型（大小写不敏感）包括：

```text
text
toolcall / tool_call / tooluse / tool_use
toolresult / tool_result
thinking / reasoning / reasoning_content
image / image_url
a2ui
```

- 工具结果还可由顶层的调用 id 或工具名字段识别；识别后角色被改写为 `toolResult`（`message-normalizer.ts:14-32`）。
- 思考内容另有 `reasoning_content`（含驼峰变体）字段，以及正文内 `think` 一类标签的兼容路径（`message-extract.ts:149-212`）。

角色分派由 `normalizeRoleForGrouping` 收口：工具结果一族的多种写法统一归为 `tool`，其余角色保留原文（`message-normalizer.ts:59-81`）。分组时工具角色被并入助手组，工具结果消息若紧跟助手组则直接追加进该组（`chat-items.ts:32-41`）。

## 2. 流式数据到 UI 的更新链

三种频率需要分开看：

- **视图更新**：每个 `delta` 到达时，流式文本被整体赋值一次，线程元素随之重建 keyed 列表并重渲染当前流式项；该 key 由会话与起始时间组成且保持稳定，列表身份不变，随分片变化的只有文本内容和重新解析出的 Markdown（`chat-items.ts:136-171`、`markdown.ts:172-206`）。
- **状态更新**：`handleChatEvent` 还写 runId、阶段、终止集合，并镜像到按会话的运行态快照（`controllers/chat.ts:557-620`、`chat/chat-session-runs.ts:117-123`）。
- **持久化**：本地不做，run 结束（完成、中止或报错）之后由网关层重载历史（`app-gateway.ts:292-304`）。

分片合并规则：`text` 优先，缺省时从 `message` 提取文本；若新分片以当前串为前缀且更长，视为旧网关的「整段快照」直接替换，否则追加（`controllers/chat.ts:568-583`）。推理分片走同样累积逻辑但单独存放。

`turn` 的语义是「一轮工具往返结束」：把该轮消息压入历史、清空流式文本与 A2UI、阶段切到工具执行（`controllers/chat.ts:584-595`）。final 时若还有未落地的 A2UI 块，先合并进末条消息再替换，并清掉「只有 A2UI 的孤儿尾消息」（`controllers/chat.ts:596-606`、`155-178`）。

完成态收口后有短暂不一致窗口：`final` 已把本地最后一条替换为服务端消息，历史重载是异步的；重载失败时 `lastError` 会显示在聊天顶部提示区。

## 3. 消息列表、窗口化与滚动

列表没有虚拟化。构建列表时先把历史裁到最近 500 条（常量 `CHAT_HISTORY_LIMIT`），被裁掉时在最前面插入一条系统角色提示「Showing last N messages」（`chat-items.ts:94-106`、`controllers/chat.ts:246`）。工具流消息另存为一路数组，只在非纯对话模式且当前无活动 run 时并入列表（`chat-items.ts:126-134`）。

实时项按优先级三选一：有 A2UI 就出 `a2ui` 项，有流式文本就出 `stream` 项，两者都没有就出 `reading-indicator` 项（`chat-items.ts:144-170`）。这解释了为什么「调用工具期间」气泡里是活动指示而不是空白。

高度与滚动靠 DOM 实测而非预算：滚动调度器在 Lit 更新完成后读取线程容器的剩余距底距离，小于 120px 视为贴底；不贴底时只置「下方有新消息」标记并显示跳转按钮，贴底时立即滚动，再做一次 120–150ms 的延迟校正（`ui/src/ui/app-scroll.ts:18-88`）。流式、A2UI 与新一轮工具往返都会请求滚动跟随（`app-gateway.ts:271-277`）。

没有分支树、minimap、消息跳转或活动路径高亮；同一会话内也搜不到消息级锚点。

## 4. 消息壳层与角色分派

四种壳层组件对应四种 item：

| 壳层 | 结构 | 用于 |
|---|---|---|
| `renderMessageGroup` | `.chat-group` + 头像 + `.chat-group-messages` + 发送者/时间脚注 + 元信息脚注 | 历史消息（用户、助手、系统、工具） |
| `renderStreamingGroup` | 同上，额外带活动状态行与 `streaming` 类 | 实时文本 |
| `renderReadingIndicatorGroup` | 头像 + 气泡内的活动状态 | 等待首个 token 或工具往返中 |
| `renderA2UIGroup` | 头像 + 活动状态 + A2UI 面板 | 实时结构化 UI |

角色分派同时决定气泡样式与发送者署名：用户显示为 You，助手显示为配置的助手名，工具显示为 Tool，其余角色沿用原值。头像在助手配置了头像地址时使用图片，没有图片则退回首字母或齿轮字符。助手组的脚注会拼装模型名、耗时、token 用量与结束时间；这些映射与脚注数据合起来定位在 `grouped-render.ts:421-484`、`529-562` 与 `chat/message-meta.ts:69-124`。

用户与助手的差异集中在 `renderGroupedMessage`：只有助手角色会提取思考块，工具卡则按 `showToolTrace` 开关提取（助手组内该开关被显式关闭，改由外层工具面板承载），复制按钮只加在助手正文上（`grouped-render.ts:1427-1540`、`1266-1301`）。系统消息没有特殊样式，落到 `other` 分支。

## 5. Markdown、代码与富文本管线

顺序是「修复 → 截断 → 解析 → 包表格 → 清洗」：

1. `normalizeMarkdownForChat` 在解析前修掉模型输出常见的六类排版粘连（`markdown.ts:11-79`）：
   - 标题与表格行挤在同一行；
   - 标题与正文挤在同一行；
   - `---` 分隔线贴住上方文字；
   - 一行里出现多个列表项；
   - 编号列表紧贴前一句；
   - 表格前缺少空行。

   同一步还会把 `csv` 围栏改写成 GFM 表格，最多保留 15 行，超出部分追加「另有 N 行未展示」。
2. 超过 14 万字符先截断并加提示；超过 4 万字符不再解析 Markdown，直接转义进 `<pre class="code-block">`（`markdown.ts:187-199`）。
3. `marked` 开启 GFM 与 breaks 两个选项（`markdown.ts:5-8`），因此单个换行也会保留。
4. 解析结果先用正则给每个 `<table>` 包一层 `.chat-md-table-wrap` 以支持横向滚动，再交 DOMPurify（`markdown.ts:208-221`）。

清洗策略是白名单：标签只保留常见排版元素（链接、代码、预格式、表格、标题、列表、图片、删除线与水平线等），属性只保留八个，用于链接跳转、图片地址与有序列表起始序号；完整清单在 `markdown.ts:81-111`。另有两条清洗后钩子：

- 清洗后还会处理附件链接：`attachments/` 开头的相对路径被改写成占位锚点并打上 `data-chat-attachment` 标记，线程的点击委托据此把它转成「打开附件」事件（`markdown.ts:147-161`、`components/openocta-chat-thread.ts:92-106`）。
- 图片地址只保留内联图片与 http(s) 两类，其它协议的 `src` 在清洗后被移除（`markdown.ts:163-168`、`223-230`）。

没有语法高亮、没有 KaTeX/Mermaid：Markdown 相关依赖只有 `marked` 与 `dompurify`，全仓未出现高亮或公式库的引用；代码块呈现为等宽 `<pre>`，样式负责换行与背景（`ui/package.json`、`ui/src/styles/chat/text.css`）。

## 6. 工具、推理、附件与自定义节点

**工具节点**由提取函数从消息内容中收集调用与结果两类卡（`ui/src/ui/chat/tool-cards.ts:10-49`）。展示名与图标来自静态表 `tool-display.json`，按工具名索引，并按参数里的 action 选择子标签、按配置的字段路径提取摘要；读、写、编辑三类另有专门的路径摘要，家目录被缩写（`ui/src/ui/tool-display.ts:159-233`）。

助手组内的工具呈现分两层：外层按工具名归组，显示「运行 N 次 · 全部成功 / 成功 x 失败 y」与运行中状态；内层每个调用是一行命令，展开后是「输入 / 输出」两段预格式文本，失败项自动展开（`grouped-render.ts:987-1074`）。工具结果消息若单独出现，走折叠块渲染，并把工具结果正文与正文里的重复内容去重（`grouped-render.ts:648-677`、`1319-1373`）。

**推理节点**有两种呈现：流式期间是 `LIVE` 标记的实时折叠面板，归档后标题变为「思考过程」（`grouped-render.ts:259-277`）；助手组内所有含思考的文本段会汇总到一个「思考过程」面板（`grouped-render.ts:1093-1129`）。推理文本经 `formatReasoningMarkdown` 包装成斜体段落再进 Markdown 管线（`message-extract.ts:253-264`）。

**附件与图片**有四种发现路径，全部汇入同一组渲染函数：

| 发现方式 | 触发形态 | 处理 |
|---|---|---|
| 内容块 | `type: image` 且 `source.type=base64`，或 `image_url`（OpenAI 形态） | 转 data URL 显示（`grouped-render.ts:185-239`） |
| 标记协议 | 文本中的 `@@OPENOCTA_ATTACHMENTS@@` 后跟 JSON 数组 | 解析出图片与文件（`chat/openocta-attachments.ts:1-109`） |
| Markdown 本地引用 | `![alt](attachments/x.png)` 或裸扩展名 | 交给 `chat-local-image`，经网关 `chat.attachment.read` 回捞（`chat/attachment-images.ts:1-50`、`components/chat-local-image.ts:50-78`） |
| 正文路径引用 | 输出里出现的 `…/file.md`、`~/x.csv`、`attachments/*.html` | 正则抽取后由 `chat-deliverable-attachments` 逐个回捞（`chat/file-blocks.ts:317-365`、`435-494`） |

最后一类是 IT Ops 场景的特征：巡检报告、告警分析常以文件路径形式出现在回答里，渲染器会把它们补成可预览的交付物列表，并用已出现的图片与文件键去重，避免同一文件显示两次（`grouped-render.ts:1189-1194`、`1302-1314`）。

**A2UI 节点**是自定义块：类型为 A2UI 的 part 先被收集、去重，再按 surface 校验，通过后交给面板元素渲染。面板更新采用增量投喂，消息前缀变化或数量回退时重建处理器并全量重放，其余情况只投喂新增部分。若某个 surface 只含纯文本容器类组件，渲染端会把文本降级成普通 Markdown，改由消息渲染处理（`chat/a2ui-bridge.ts:269-379`、`components/chat-a2ui-panel.ts:200-243`、`grouped-render.ts:1389-1392`）。

## 7. HTML、Artifact 与内容承载边界

- **Markdown 内的 HTML**：内联 HTML 与解析产物一起进入 DOMPurify 白名单，脚本、样式、内嵌框架标签和事件属性都会被过滤，`javascript:` 链接同样被清除；白名单定义与对应的清洗断言见 `markdown.ts:81-111`、`markdown.test.ts:10-23`。
- **外链**：锚点统一输出为带 `target="_blank"` 与 `rel="noreferrer noopener"` 的新窗口链接；`attachments/` 开头的相对路径在点击后转为附件打开（`markdown.ts:147-161`）。
- **A2UI 面板**：组件由 `@a2ui/lit` 的 basic catalog 直接渲染进同一文档，没有 iframe 隔离。catalogId 在渲染前做别名归一，basic、standard、default 都收敛到库内置的 basic catalog，未知取值原样透传；单个面板处理失败时退化为一行错误文案，异常停在该面板内部（`a2ui-bridge.ts:13-52`、`chat-a2ui-panel.ts:239-259`）。
- **文件预览**：图片以 `<img>` 直接展示；PDF 与 HTML 交给 `<iframe src=…>`，该 iframe 未设置 `sandbox` 属性；其余文本类内容在本地解码后按类型渲染成 Markdown、CSV 表格、JSON 美化文本或纯文本（`components/chat-file-preview.ts:225-232`、`chat/file-preview-content.ts:151-174`）。
- **本地文件**：本地文件不走 `file://` 直读，内容统一经网关 `chat.attachment.read` 取回 base64 再转成 data URL，渲染器接触到的只是 data URL（`chat/attachment-cache.ts:17-50`）。

## 8. 内容交互反馈与可访问性

- 复制按钮有三种反馈状态：空闲、已复制、失败。复制进行中通过 `aria-busy` 与禁用属性挡住重复点击，约 1.5–2 秒后自动回到空闲；在非安全上下文里退回 `execCommand` 完成复制（`chat/copy-as-markdown.ts:15-102`）。
- 折叠交互沿用原生 `<details>` 与 `<summary>`，键盘可直接操作；工具结果另有一枚自绘展开按钮，展开状态同步写入 `aria-expanded` 与 `hidden`（`grouped-render.ts:679-694`）。
- 工具卡具备点击行为时补上 `role="button"` 与 `tabindex="0"`，并单独处理 Enter 与 Space 键（`tool-cards.ts:87-104`）。
- 文件预览以 `role="dialog"` 与 `aria-modal="true"` 呈现，遮罩层本身是可聚焦按钮，标题栏放置下载与关闭入口（`chat-file-preview.ts:246-268`）。
- 活动行与 A2UI 面板这类观察类提示使用 `aria-live="polite"`；消息线程本身声明 `role="log"`，并把 `aria-live` 设为 `off`（`grouped-render.ts:287-292`、`openocta-chat-thread.ts:56-63`）。
- A2UI 交互动作提交时先移除同一 surface 上的旧块，再发出 `chat.a2ui.action`，新 run 启动后面板随之清空（`controllers/chat.ts:181-228`）。

## 9. 性能、缓存与测试

| 机制 | 位置 | 作用 |
|---|---|---|
| 文本/思考 WeakMap 缓存 | `message-extract.ts:21-22`、`136-147`、`214-225` | 同一消息对象在一次渲染中被多处提取时不重复计算 |
| Markdown LRU | `markdown.ts:113-139` | 最多 200 条、单条 ≤5 万字符，命中时刷新顺序 |
| 工具流节流 | `app-tool-stream.ts:4-6`、`145-157` | 300ms 合并、最多 50 条、单条输出 12 万字符截断 |
| 历史裁剪 | `chat-items.ts:95-106` | 超 500 条时丢弃更早消息并提示 |
| 大文本降级 | `markdown.ts:187-199` | 超 4 万字符不解析，直接转义显示 |
| A2UI 增量投喂 | `chat-a2ui-panel.ts:216-238` | 只在新增或前缀变化时重放 |
| 附件回捞缓存 | `chat/attachment-cache.ts:6-50` | 按会话+路径缓存，并在同 key 并发时复用 promise |

没有为聊天文本做批量合并或节流，也没有虚拟滚动；流式期间每来一个分片就会新建一个字符串并重新解析整段 Markdown（缓存键是全文，因此基本只有重复渲染同一文本时才命中）。

测试覆盖集中在可独立验证的部分：

- Markdown 渲染与清洗：`markdown.test.ts`、`chat-markdown.browser.test.ts`
- A2UI 归一与去重：`chat/a2ui-bridge.test.ts`
- 附件与 CSV 解析：`chat/file-blocks.a2ui.test.ts`、`file-blocks.paths.test.ts`
- 消息归一与运行态：`message-normalizer.test.ts`、`chat/chat-session-runs.test.ts`
- 滚动：`app-scroll.test.ts`

本次未找到针对长会话渲染性能的基准或快照测试。

## 10. 扩展方式与已确认边界

新增一种内容形态需要同时改四处：提取函数（把消息里的新形态转成结构化对象）、`renderGroupedMessage` 或助手段切片中的分支、`unsafeHTML` 之前的清洗/转义决策、以及对应 CSS。工具展示是配置驱动的例外：只加 `tool-display.json` 条目即可获得标题、图标、子动作与摘要字段（`tool-display.ts:32-34`、`159-207`）。

按实现结构推断，A2UI 的扩展点主要在服务端：新增组件类型沿用 `@a2ui/lit` 的目录，渲染端只需保证 catalogId 归一与去重逻辑能处理新的消息种类（`a2ui-bridge.ts:96-120`）。

已确认边界：

- 不解析 LaTeX、Mermaid、脚注扩展或代码高亮。
- 不做消息级分页、折叠历史、虚拟化或跳转锚点。
- 渲染函数本身不改写消息对象；对 A2UI 块的合并/去重与对「只有 A2UI 的尾消息」的裁剪发生在控制器的状态更新里，不在渲染阶段。
- 图片只信任 data URL 与 http(s)；其它协议会被清空，因此本地图片必须经网关回捞。
- 若消息正文同时包含工具结果与汇总文本，渲染器会按字符串包含关系去重，避免「工具卡 + 相同正文」重复出现；去重是启发式的（`grouped-render.ts:648-677`）。

## 11. 未验证事项

- 未运行浏览器：流式期间整段 Markdown 重解析的实际输入延迟、超长文本折行与表格横向滚动表现均未测量。
- 未验证 `gfm + breaks` 同时开启在真实运维输出（日志、堆栈、表格混合）下的排版效果。
- A2UI 面板在复杂 surface、并发多 surface 与提交动作后的重放行为只做了静态推演。
- HTML/PDF 预览的 `iframe` 未加 `sandbox`，实际加载来源全部是网关返回的 data URL；对远程 URL 的行为未验证。
- 交付物路径正则在不同操作系统路径与中文文件名下的召回/误召回率未验证。
- 单轮助手消息被切成多段后的阅读顺序依赖段类型与出现顺序，实际观感未验证。

## 12. 关键源码索引

- `ui/src/ui/components/openocta-chat-thread.ts:49-175`：线程元素与 item 分派。
- `ui/src/ui/chat/chat-items.ts:18-174`：分组、key 生成、实时项插入。
- `ui/src/ui/chat/grouped-render.ts:455-527`、`1171-1316`：消息组与助手轮次切片。
- `ui/src/ui/chat/grouped-render.ts:987-1074`、`1319-1373`：工具段与折叠结果块。
- `ui/src/ui/chat/grouped-render.ts:1427-1541`：单条消息的组件装配。
- `ui/src/ui/markdown.ts:11-239`：修复、解析、缓存与清洗。
- `ui/src/ui/chat/a2ui-bridge.ts:1-397`、`ui/src/ui/components/chat-a2ui-panel.ts:200-288`：A2UI 归一、去重与渲染。
- `ui/src/ui/chat/file-blocks.ts:317-539`、`744-`、`ui/src/ui/chat/file-preview-content.ts`：交付物发现与文件预览。
- `ui/src/ui/chat/message-extract.ts:102-264`、`message-normalizer.ts:10-90`：文本、思考与角色归一。
- `ui/src/ui/tool-display.ts`、`ui/src/ui/tool-display.json`：工具展示表。
