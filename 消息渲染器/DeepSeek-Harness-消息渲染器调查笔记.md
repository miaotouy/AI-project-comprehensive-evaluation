# DeepSeek Harness 消息渲染器调查笔记

> 调查对象：`../../deepseek-harness`（重点 `apps/web`、`packages/client/ui-*`、`packages/core/tools`、`packages/host/apiproxy`、`packages/session/session-projection`）
>
> 调查更新日期：2026-08-16
>
> 代码快照：`47f943859bef60e4160492346772ded9b24f765a`（分支：`master`）
>
> 调查方式：静态源码阅读（只读检查 git 工作树）；未运行应用、测试与快照回放
>
> 调查范围：覆盖——输入数据模型、流式更新链、列表与滚动、消息壳层、Markdown/代码/数学管线、呈现意图词汇与工具卡片、交互反馈、性能与测试、扩展机制、session-projection 投影来源、schema-form 与 agent-tool-presentation 边界；排除项——视觉效果与键盘可用性（需运行验证，本次未运行）、宿主侧会话持久化细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

1. **本仓库不是聊天应用，没有传统意义上的"消息渲染器"组件**：deepseek-harness 是基于 vendored Cordis 的 agent harness，消息渲染全部发生在 Web UI 的 client 侧，实际是一条分层管线——宿主按工具声明的呈现函数计算渲染意图，随会话事件流下发；client runtime 把事件折叠成快照；ui-conversation、ui-tool、ui-primitives 三组插件负责绘制。`apps/cli` 是 `dsh` 命令行入口（配置、插件管理、浏览器别名），不承担消息渲染。
2. **输入模型是事件流 + 宿主附带的渲染意图**：client 消费会话日志事件 `SessionEvent`；assistant 流内是 `StreamChunk` 联合（增量、块界、usage/finish 等七种，`packages/llm/llm/src/types.ts:291-303`）；`tool/call` 与 `tool/result` 事件可附带宿主计算的 `ToolEventView`（呈现意图），该意图不持久化，回放时宿主重算（`packages/host/apiproxy/src/api/events.ts:24-34`）。
3. **流式链路是"逐 chunk 折叠、按帧发布、增量渲染"**：块级不可变的折叠有两处实现（`PartialAccumulator` 与 assistant Definition），可见 chunk 请求 `animation-frame` 发布、同帧合并（`notifier.ts:44-50`）；`MarkdownText` 的增量解析器只重解析尾部两块、冻结块缓存为 React 元素（`markdown/incremental.ts:75-129`）。
4. **呈现意图是纯函数契约**：presentCall/presentResult 必须是无 I/O 的 args 纯函数，defineTool 对回放中的旧参数做软校验、失败即降级 generic（约定与实现见 `adding-a-tool.md:86`、`schema.ts:594-609`）。结果期结构化事实经 output.presentationMeta 随日志持久化，回放时由 presentResult 读回（范例 `packages/fs/tool-fs-search/src/presentation.ts`）。
5. **工具卡片按 card 判别分派为六类**（完整对照见第 6 节表格），client 侧由各卡片模型派生渲染 props；另有按工具名注册的 keyed 槽位 `tool.call.toolview` 支持专属卡片（cordis_define 即此路）。
6. **Markdown 管线是自建 mdast→React 直接渲染**：raw HTML 以字面文本输出、链接与图片只放行 http(s)/mailto、流式与收口用两套语法（流式无数学与高亮）、KaTeX 与 shiki 均无用户 HTML 注入面。
7. **性能与列表**：增量块解析 + 冻结元素缓存 + RAF 帧合并 + 语法惰性加载；聊天列表无虚拟化（keyed 行 + 分页 + 滚动锚点），trajectory 视图是独立表面且带虚拟行。

## 总体渲染链路

```text
LLM 流 (assistant/chunk) 与工具事件 (tool/call, tool/result)
  -> host api-proxy viewFor()：ctx.tools.get(name, scope).presentCall / presentResult
     计算 ToolEventView（不持久化；history 路径用 backscanArgs 配对 call）
  -> mux 流 session/event(+view) -> SessionManager.handleMuxEnvelope -> Session.acceptLiveEvent
  -> ConversationNodeAssembler.append()：各 ConversationNodeDefinition 的 match/start/update 折叠
  -> publication 分级：immediate(microtask) 或 animation-frame(RAF) -> Notifier 重建快照
  -> ChatView 读取 chat.order，ChatNodeSeat 按 key 订阅单个节点
  -> 节点渲染器：AssistantMarkdown(MarkdownText) / ToolCallTree(GenericToolCard 或 keyed toolview)
```

宿主侧计算入口在 `packages/host/apiproxy/src/api-proxy.ts:744-780`（`viewFor` 捕获 presenter 抛错并软降级）。client 侧事件进入窗口的路径见 `session.ts:668-703`（seq 去重与缺口修复的追加逻辑）。

## 1. 消息与内容块数据模型

- **事件流为唯一输入**：`Session` 维护连续事件窗口（history 装载 + live 缓冲拼接），`ConversationNodeAssembler` 把每个事件交给注册的 Definition 折叠出业务上下文（`runtime/src/client/sessions/conversation-assembler.ts:194-215`）。
- **assistant 内容块**：`AssistantBlock` 是渲染器的最小内容单元，kind 取五值——text、reasoning、image、tool-call、other（`runtime/src/client/sessions/conversation.ts:44-73`）；流式、收口、中断三种状态共享一个按 turn:step 标识的节点（`ui-conversation/src/client/conversation-nodes/assistant.ts:244-309`）。
- **工具块**：`ToolResultNode` 与 `RunningToolCall` 组成 `ToolCallBlock`，携带来自帧的 `callView`/`resultView` 与递归 `subCalls`；窗口截断时结果块退化为无 call 头（`conversation.ts:183-310`）。
- **渲染节点**：`ChatNode` 的 kind 与 payload 通过 `ChatNodeDataMap` 声明合并扩展（`ui-conversation/src/client/contract/chat-nodes.ts:6-39`），`ChatNodeSeat` 按 key 订阅并路由到 keyed 槽位 `conversation.chat.node`（`chat/ChatNodeSeat.tsx:19-61`）。

## 2. 流式数据到 UI 的更新链

- **chunk 折叠**：`PartialAccumulator` 以块下标稀疏数组累积五种可见 chunk（block-start、三种 delta、block-end），只替换该块的引用；usage/finish 不算可见变化（`runtime/src/client/sessions/partial.ts:23-103`）。assistant Definition 的 `updateChunk` 做同样的折叠，并顺带记录首可见块与首 token 时间（`assistant.ts:80-132`）。
- **发布节流**：流式 chunk 请求 `animation-frame` 发布，`Notifier.markFrameDirty` 用 requestAnimationFrame 合并同帧多次更新（`notifier.ts:44-50`）。收口与 tool/result 事件则走 immediate 的 microtask 发布（`assistant.ts:278-283`）。
- **增量渲染**：`MarkdownText` 流式时用增量解析器，只重解析末尾两块，冻结块缓存为 React 元素，块以源码偏移作稳定 key 保证 React 复配而非重挂载（`markdown/incremental.ts:75-129`、`markdown/MarkdownText.tsx:59-138`）。
- **收口与中断**：`assistant/message` 以完整 content 替换折叠块并立即发布（`assistant.ts:264-272`），`streaming` 标志翻转后 `MarkdownText` 全量重解析（数学与高亮落地）；turn/step 关闭边界处若残留可见块，生成合成 seq 的 `interrupted` 节点并渲染"已停止"标记（`assistant.ts:145-181`）。

## 3. 消息列表、窗口化与滚动

- **无虚拟化**：ChatView 是稳定 keyed 的节点列表，每个 `ChatNodeSeat` 只订阅自己的节点 key，assistant 增量只替换自身行（`chat/ChatView.tsx:382-397`）。
- **分页**：`hasMore` 与"加载更早"按钮做 prepend，加载后按 `data-chat-anchor-key` 锚点保持阅读位置（`ChatView.tsx:349-363`、:237-249）。
- **滚动**：底部跟随阈值 24px，滚动归属用"观察顶账本"区分程序写入与读者输入（滚轮/触摸/滚动条/键盘统一处理），钉底时 ResizeObserver 跟随流式高度变化（`ChatView.tsx:264-299`、:331-341）。
- **trajectory 是独立表面**：时间线视图用纯投影把记录折叠为可测量的虚拟行（`ui-trajectory/src/client/trajectory-virtual-rows.ts:51-83`），与聊天列表的滚动策略互不相干。

## 4. 消息壳层与角色分派

- **用户与 steering**：右对齐气泡，文本经 `MessageText` 字面渲染（不解析 markdown），斜杠与 @ 开头的词法 token 装饰为 skill/subagent 标签，图片走 ImageGallery（`chat/MessageItem.tsx:157-205`）。
- **助手**：`AssistantMarkdown` 按块序渲染——text 块进 `MarkdownText`（带 streaming 标志）、reasoning 块进 Think 折叠行、image 块连续合并成画廊、tool-call 头不在此渲染而由 chat 视图分组为工具行（`chat/AssistantMarkdown.tsx:37-110`）。
- **其他节点**：context 注入行、compaction 标记、model-retry 倒计时、turn-error / turn-max-tokens 状态行、unknown JSON 兜底，全部经 `registerChatNodeRenderers` 注册到 keyed 槽位（`chat/register-node-renderers.ts:15-51`）。
- **操作栏**：turn-tail 节点承载复制/反馈/分支等 IconActions，仅在该 turn 的收尾助手节点就绪时挂载（`chat/AssistantNodeView.tsx:14-22`）。

## 5. Markdown、代码与富文本管线

- **两套语法**：流式用纯 GFM（无数学，避免半截 TeX 触发 KaTeX 报错），收口用 GFM + 数学；两者都带 CJK 友好加粗与数学兼容定界符（`markdown/parse.ts:26-44`）。
- **渲染顺序**：自建 mdast→React 直接 switch，替换了 react-markdown 管线，DOM 结构由 `tests/fixtures/markdown-dom/` 的 settled/streaming 成对夹具按字节钉住；引用定义、脚注编号在流式帧间累积（`markdown/render.tsx:146-298`、:543-583）。
- **代码高亮**：shiki core（纯 JS 正则引擎，不打包 oniguruma WASM），引导只加载三个语法，其余 23 个语法按首次使用动态 import；语法未就绪先渲染纯文本、加载完成后再补高亮（`markdown/highlight.ts:42-77`、`markdown/CodeBlock.tsx:26-74`）。
- **数学**：KaTeX 输出经 DOMParser 映射为 React 元素，三层错误链与 rehype-katex 对齐；`` ```math `` 围栏在收口后渲染为显示 TeX（`markdown/katex.tsx:66-90`、`render.tsx:313-317`）。
- **链接、图片与原始 HTML**：链接目的地经归一化后仅 http(s) 与 mailto 三种协议放行，未命中渲染为纯文本；图片仅接受绝对 http(s) 地址并带懒加载与 no-referrer；`html` 节点以字面文本输出，无 HTML 进入 DOM（`render.tsx:37-62`、:261-263、:471-487）。

## 6. 呈现意图词汇与工具卡片

- **词汇表**：调用期 `ToolCallView` 与结果期 `ToolResultView` 是 card 判别联合（`packages/core/tools/src/presentation.ts:46`、:140）。结果期视图用 `shape`/`kind` 二次判别，wire 上出现未知取值时一律降级到 generic 路径（各卡片模型都有此分支）。
- **卡片种类**（结果期视图按 `shape`/`kind` 二次判别）：

| card | 内容 | 典型来源 | client 映射 |
|---|---|---|---|
| generic | 标题 + 可选 rawInput/content/locations | 未声明呈现的工具 | 通用行 |
| terminal | cwd 头 + 命令 + 输出 + exitCode/signal | bash、pwsh | TerminalBlock |
| diff | 文件改动 hunks（oldText 为 null 表示新建/覆写） | write、edit | DiffBlock |
| search | matches 按文件分组或 paths 平铺，带 truncated/total | grep、glob | SearchBlock |
| read | 行号 + 语法高亮窗口 + totalLines | read | ReadBlock |
| web | 引用来源列表（kind: search）或抓取摘要（kind: fetch） | web_search、web_fetch | WebBlock |

- **纯函数约束**：呈现器在实时流式与会话日志回放两处都会运行，故必须是无 I/O、不读会话状态、不用时钟/随机的 args 纯函数；会话上下文（如 cwd）由 UI 适配器补足（cookbook 明文，`adding-a-tool.md:86`）。`defineTool` 对回放中任意旧参数做软校验，不匹配返回 undefined（`schema.ts:594-609`）；宿主侧再兜一层异常捕获（`api-proxy.ts:774-780`）。
- **结果期事实经 meta 传递**：search/read/web 的结构化数据无法从模型可见文本无损恢复：工具用 `output.presentationMeta` 把结构化 JSON 写入结果事件的元数据（随日志持久化），`presentResult` 读回并防御性窄化（`presentation.ts:130-205`）。
- **client 卡片派生**：`GenericToolCard` 依次派生行模型与五类卡片模型；行模型按工具名分类为 `ToolRowVariant`（七类行变体，`tool-call-model.ts:37-78`）并从 args 取摘要、从结果取扁平输出（`toolviews/GenericToolCard.tsx:36-77`、`tool-call-model.ts:211-240`）。各卡片模型处理 wire 上未知 card/kind 值的降级（如 `models/web-card-model.ts:39-74`）。
- **专属工具视图**：`ToolCallTree` 经 keyed 槽位 `tool.call.toolview` 按工具名分派，未注册则回退 `GenericToolCard`（`tool/ToolCallTree.tsx:38-41`）。
- **cordis 卡片**：ui-cordis 为 cordis_define/cordis_run 注册专属卡片（`extensions/ui-cordis/src/client/card-model.ts:95-161`）。
- **reasoning 呈现**：Think 折叠行，流式中摘要显示最新一行并保持滚动跟随（`chat/ReasoningRow.tsx:27-65`）。

## 7. HTML 与内容承载边界

- 运行时不承载 HTML/iframe/Artifact：模型输出只经 `MarkdownText` 管线，raw HTML 保持字面文本；唯一 `dangerouslySetInnerHTML` 是 shiki 生成的静态 span 树（`CodeBlock.tsx:52-57`）。
- 数学与代码的 HTML 来源可信：KaTeX 输出经 DOMParser 映射为 React 元素，词汇表限定 span/MathML/SVG（`katex.tsx:88-89`）。
- 链接与图片目的地过白名单；行内代码的文件提及由调用方解析器决定 token 是否对应真实文件，渲染器不猜测（`render.tsx:107-115`、:243-258）。
- `schema-form` 是设置编辑器的 schema/草稿模型层（schemastery 重水化 + 按路径不可变编辑），与消息渲染无关（`packages/client/schema-form/src/index.ts`）。
- `agent-tool-presentation` 的 `presentAs`（native/code/both）选择的是模型可见的工具面，不是 UI 渲染——命名与"呈现"撞词，实际语义在 `packages/core/tools/src/index.ts:946-971`，特此澄清边界。

## 8. 内容交互反馈与可访问性

- 复制：fence 复制按钮带 1 秒"复制成功"确认窗口，剪贴板写入经统一封装（`CodeBlock.tsx:36-46`）；行操作栏另有图标复制。
- 展开/折叠：DisclosureRow 支撑工具行、Think 行与 terminal 卡片；卡片默认折叠，长内容在行内 max-height 容器中滚动；details 面板是单调用全高阅读面（`tool/ToolDetails.tsx:25-66`）。
- 运行状态反馈：工具行用 StateDot 着色并配隐藏文本状态（`ToolRow.tsx:119-126`）；terminal 卡的非零退出码/信号映射为错误红点（`models/terminal-card-model.ts:72-75`）；turn 级"Deep diving..."时钟在运行 15 秒后出现（`ChatView.tsx:107-140`）。
- 键盘与无障碍细节（焦点环、锚定语义、复读行为）需运行验证，见未验证事项。

## 9. 性能、缓存与测试

- 增量解析把整篇重解析（随回复长度二次增长）降为尾部小区域解析；冻结块缓存 React 元素且 key 稳定，跨冻结边界复配而非重挂载（`markdown/incremental.ts`、`MarkdownText.tsx`）。
- 块级不可变与 memo 组件配合（助手、节点座、工具调用行等），chunk 帧合并经 `markFrameDirty`。
- shiki 在模块加载后延迟构造并预 tokenize 三个引导语法，懒加载语法避免首包携带约 1.6MB 语法模块（`highlight.ts:159-186`、:244-251）。
- 测试证据（均未运行）：DOM 字节级 parity 夹具、增量行为单测、组装快照测试（`apps/web/tests/search-card.snapshot.ts` 以文本字段钉住 grep 卡）、若干 markdown 与数学 e2e 的 `ui.expected.md`（可访问性树文本）、trajectory 虚拟化 e2e。

## 10. 扩展方式与已确认边界

- 新工具卡片：工具声明 `presentCall`/`presentResult`（纯函数），需要专属外观时再注册 keyed `tool.call.toolview` 条目（ui-cordis 是完整范例）。
- 新消息节点：注册 `ConversationNodeDefinition`（match/start/update/buildViewNode）+ keyed `conversation.chat.node` 渲染器；折叠按日志 seq 确定，可确定性重放（`ui-conversation/src/client/conversation-nodes/`）。
- 新投影：在 `SessionProjectionMap` 上声明合并 + 注册纯 init/apply/view 单元，框架负责驱动与变更通知（`packages/session/session-projection/src/index.ts:42-74`、:405-425）。
- 已确认边界：渲染意图不落盘（同一事件在不同交付可能带不同或没有视图，回放由宿主重算）；流式期间无高亮/数学/文件提及，收口才全量渲染；聊天列表无虚拟化，超长会话渲染成本线性增长；UI 展示数据不进入会话日志（"web 层是纯展示"的仓库规则）。

## 11. 未验证事项

- 视觉效果、键盘可用性、滚动手感未运行验证；jsdom 快照只能证明文本与 DOM 结构。
- 流式帧率与长会话性能未测量（`complex-history.perf.ts` 存在但未运行）。
- 浏览器中 shiki CSS 变量主题、KaTeX MathML 分支、懒加载图片的实际呈现未观察。
- 会话日志回放重算视图（history 路径）与 live 路径是否完全一致未实测。

## 12. 关键源码索引

- `packages/core/tools/src/presentation.ts`：渲染意图词汇全集
- `packages/host/apiproxy/src/api-proxy.ts:744-780`：宿主计算 ToolEventView；`api/events.ts:24-34`：wire 形态与不持久化说明
- `packages/core/tools/src/schema.ts:594-609`：presenter 软校验包裹；`docs/cookbook/adding-a-tool.md:69-89`：呈现纯函数约定
- `packages/client/runtime/src/client/sessions/partial.ts:23-103`：chunk 折叠；`notifier.ts:44-50`：帧合并
- `packages/client/ui-conversation/src/client/conversation-nodes/assistant.ts:244-309`：assistant 节点与发布分级
- `packages/client/ui-primitives/src/markdown/MarkdownText.tsx:156-176` 与 `incremental.ts:75-129`：增量渲染；`render.tsx`：mdast→React 与安全边界
- `packages/client/ui-tool/src/client/tool/toolviews/GenericToolCard.tsx:36-77` 与 `models/*`：卡片分派与派生；`tool/ToolCallTree.tsx:38-41`：keyed toolview 槽位
- `packages/extensions/ui-cordis/src/client/card-model.ts:95-161`：cordis 专属卡片
- `packages/fs/tool-fs-search/src/presentation.ts`：presentationMeta 投影与窄化范例
- `packages/session/session-projection/src/index.ts:42-74`：投影注册契约
- `packages/client/ui-conversation/src/client/chat/ChatView.tsx`：列表、分页与滚动锚点
