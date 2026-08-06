# AIO Hub 消息渲染器调查笔记

> 调查对象：`E:\works\git\aio-hub`
>
> 调查更新日期：2026-07-29
>
> 代码快照：`eba9d84b234672321312e92ab48bb474cfb0aca4`（分支：`main`）
>
> 调查方式：只读源码梳理；未修改目标仓库
>
> 调查范围：消息模型、Markdown/富文本、流式更新、列表和扩展渲染机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AIO Hub 的“消息渲染器”实际由两层组成：

1. `llm-chat` 负责消息树、消息类型分派、附件、独立推理、翻译、编辑、流式状态和列表滚动。
2. `rich-text-renderer` 负责把正文字符串解析为 AST，再通过 Patch 增量更新 Vue 组件树。

桌面端默认使用自研的 `V2_CUSTOM_PARSER`。这套面向 LLM 输出的富文本运行时以 Markdown 为基础，还支持：

- Markdown、嵌套 HTML、代码块、KaTeX、Mermaid、图片/音视频；
- `<think>` 等可配置思考标签；
- VCP 工具请求、角色分隔、调用结果和日记节点；
- 正则显示规则、宏展开后的规则、Agent 资产协议；
- 流式平滑、稳定区/待定区拆分、AST diff、Patch 节流；
- HTML/SVG 代码块的 iframe 交互预览；
- Agent/User Profile 级 Markdown 样式覆盖。
- 桌面端与移动端各自提供内建的人工操作测试页；桌面测试台可直接驱动生产渲染器、模拟 Token 流和检查 AST/稳定区。

这套实现将**流式正文与低频持久化分离**，并把 **AST 节点按类型交给专用 Vue 组件**。解析和状态层因此较复杂，但能保持流式输出稳定，并容纳富内容与业务协议。相应的限制集中在 HTML 执行环境、超长会话的常驻成本，以及桌面端与移动端的能力差异。

另外，当前实现没有“插件注册自定义消息渲染器”的运行时接口。设置项只是从固定 `RendererVersion` 枚举中选版本；文档中的插件渲染器仍是未来能力。

## 产品与生态背景

只看 `rich-text-renderer` 容易把 AIO Hub 理解为一个自研 Markdown/AST 项目；结合聊天上游，产品方向更接近“用结构化实现承接 VCPChat 与 SillyTavern 的常用体验”。这些导入和转换服务不属于 renderer 本体，但它们决定了正文中为什么会出现 VCP 节点、Agent 资产、显示正则、世界书内容和混合 HTML：

- `src/tools/agent-manager/services/agentImportService.ts` 与 `src/tools/llm-chat/services/sillyTavernParser.ts` 支持 SillyTavern Character Card V2/V3；JSON 与 PNG 卡均可导入，并转换人设、开场白、预设消息、正则脚本和嵌入式世界书。
- `src/tools/agent-manager/components/assets/STPresetImportDialog.vue` 直接导入 SillyTavern Context Preset；parser 会读取 `prompts` 与 `prompt_order`，再转换为 AIO 的预设消息和注入位置。
- `src/tools/st-worldbook-manager/services/worldbookImportService.ts` 支持独立 JSON/`.lorebook` 世界书，也能从角色卡 PNG 或 AIO Bundle 中提取世界书。
- `src/tools/agent-manager/services/vcpChatAgentImportService.ts` 和 `VcpChatAgentImportDialog.vue` 可以扫描 VCPChat 目录，将 Agent 配置、模型参数、正则和头像转换为 AIO 导入包。
- README 另外明确列出 ST 正则脚本、快捷动作、世界书编辑器、PNG 角色卡和 VCP 连接器兼容。

因此，AIO 与 VCPChat/ST 的接近主要发生在**资产迁移、上下文玩法、私有协议和富消息体验**上；实现路线仍然不同。AIO 试图把这批输入转换为自己的 Agent 数据、上下文管道、typed AST 和专用 Vue 节点，HTML 小应用则放入 iframe。它没有复刻 SillyTavern 全部 DOM/扩展事件契约，也没有默认采用 VCPChat 在宿主主文档中运行消息脚本的方式。“可直接导入常用社区资产”和“完全兼容原项目全部运行时行为”需要分开评价。

## 总体调用链

```text
LLM adapter / response callbacks
  -> useChatResponseHandler.handleStreamUpdate()
       -> appendStreamingMessageChunk(nodeId, delta)     高频显示通道
       -> rAF/定时批量写 ChatMessageNode.content         低频同步与持久化通道
  -> MessageList
       -> CompressionMessage     压缩节点
       -> ToolCallMessage        role=tool
       -> ChatMessage            普通 user/assistant/system
            -> MessageHeader
            -> MessageContent
                 -> AttachmentCard
                 -> LlmThinkNode + RichTextRenderer      provider reasoning
                 -> RichTextRenderer                     正文
                 -> RichTextRenderer                     翻译
            -> MessageMenubar
  -> RichTextRenderer
       -> 预处理（换行/正则/裸 HTML 防御/资产）
       -> StreamController（可选平滑）
       -> StreamProcessorV1 或 StreamProcessorV2
       -> stable AST + pending AST -> diff -> Patch[]
       -> useMarkdownAst（rAF 节流和不可变更新）
       -> AstNodeRenderer -> 专用节点组件
```

## 1. 消息壳层

### 1.1 消息数据模型

核心类型为：

- `src/tools/llm-chat/types/message.ts`：`ChatMessageNode`
- `src/tools/llm-chat/types/session.ts`：会话索引和详情

`ChatMessageNode` 以树节点保存消息，通过 `parentId`、`childrenIds` 和会话 `activeLeafId` 表达分支。正文仍以单一 `content: string` 为主，富内容主要放在附件和 metadata 中。

与渲染直接相关的 metadata 包括：

- `reasoningContent` 与推理时间；
- `translation`；
- `toolCall` / `toolCalls` / `toolCallsRequested`；
- `partialImagePreviews`；
- `usage`、模型/Profile/Agent/User Profile 快照；
- 错误和空响应诊断；
- 压缩节点信息。

AIO 的 UI 数据模型没有采用 Cherry Studio 的结构化 `parts[]`。正文里的 `<think>`、VCP 标记等仍由渲染器解析；provider 原生 reasoning、工具节点和附件则有独立结构。

### 1.2 列表分派

`src/tools/llm-chat/components/message/MessageList.vue:652` 遍历活动路径上的全部消息，并按以下优先级分派：

| 条件 | 组件 |
|---|---|
| `metadata.isCompressionNode` | `CompressionMessage` |
| `role === "tool"` | `ToolCallMessage` |
| 其他 | `ChatMessage` |

`ChatMessage.vue` 是普通消息壳，组合 `MessageHeader`、`MessageContent` 和 `MessageMenubar`。独立工具结果由列表级专用组件渲染，不进入正文 AST；VCP 协议块则能在正文内部被 V2 解析成 `vcp_tool` 节点，因此工具内容有两条渲染路径。

### 1.3 MessageContent 的职责

`src/tools/llm-chat/components/message/MessageContent.vue` 是聊天与富文本引擎的主要适配层，负责：

- 附件卡片和文档预览；
- provider reasoning 的独立折叠块；
- 正文、译文的显示模式；
- 编辑器切换；
- Agent/User Profile/全局渲染样式合并；
- render 阶段正则规则的来源合并、角色/深度过滤和宏展开；
- `agent-asset://`、`【file::assetId】`、本地路径和 VCP 表情 URL 解析；
- token/字数/错误/空响应诊断；
- HTML 预览冻结与不可见消息配置冻结。

预设消息会在显示时执行宏；普通历史消息被认为在发送时已经展开，不会二次执行正文宏。显示正则则始终在渲染器预处理阶段执行。

## 2. 流式数据链

### 2.1 Replayable StreamSource

`src/tools/llm-chat/composables/chat/useStreamingMessageSources.ts` 为每个 `nodeId` 维护一个 `ReplayableMessageStreamSource`：

- `subscribe()` 会向后加入订阅者，并通过 microtask 重放已有 buffer；
- `append()` 同步广播新 delta；
- `onComplete()` 通知终止；
- 完成后默认延迟 30 秒 dispose，给组件交接和重挂载留出窗口。

`MessageContent.vue:276` 仅在节点确实处于 generating 且 store 仍认定 executor 活跃时提供 stream source。进入生成态会通过 key remount 一次，让原静态渲染器订阅流；结束时保持同一组件实例，避免 HTML iframe 和 AST 子树整体重建。

### 2.2 显示与持久化分流

`src/tools/llm-chat/composables/chat/useChatResponseHandler.ts:242` 的正文 delta 首先进入 `appendStreamingMessageChunk()`，渲染器直接消费高频流。

同一 delta 还进入 `persistBuffer` / `syncBuffer`，再按帧或定时器批量写入 `ChatMessageNode.content`，用于：

- 会话持久化；
- 跨窗口 `chat:streaming-delta` 同步；
- 最终响应交接。

这个设计避免每个网络 chunk 都改动大对象 store、触发整条消息链响应式更新。分离窗口只接收增量事件，并把正文 delta 同样追加到本地 StreamSource。

### 2.3 推理流是另一条路径

provider 的 reasoning delta 不进入正文 StreamSource，而是按 rAF 合并到 `metadata.reasoningContent`。`MessageContent` 再用顶层 `LlmThinkNode` 包住另一个 `RichTextRenderer`。

模型直接在正文输出的 `<think>` / `<thinking>` 则由 V2 parser 识别为 AST 内 `llm_think`。因此系统同时支持“协议级 reasoning”和“文本标签 reasoning”。

## 3. RichTextRenderer 入口

文件：`src/tools/rich-text-renderer/RichTextRenderer.vue`

入口支持两种互斥输入：

- `content + isStreaming`：响应式完整文本；
- `streamSource`：订阅 delta，优先于静态 content。

关键配置包括：

- 解析：`version`、`llmThinkRules`、`regexRules`；
- 资源：`resolveAsset`；
- 样式：`styleOptions`；
- 流控：`smoothingEnabled`、`throttleEnabled`、`throttleMs`；
- 节点行为：HTML 自动预览、代码/工具折叠、无边框模式、进入动画；
- HTML：外部资源开关、危险标签开关、CDN 本地化、预览冻结；
- 护栏：`safetyGuardEnabled`。

预处理顺序是：

```text
CRLF 归一化
  -> render 正则规则
  -> 流式末尾残缺 HTML 标签隐藏（仅 streamSource 路径）
  -> 裸 <!DOCTYPE html> 自动包进 ```html fence
  -> Pure Markdown-it 模式全局 resolveAsset
  -> 补末尾换行
```

AST 模式不再全局替换资产 URL，而由 Image/Video/Audio/GenericHtml/HTML Preview 节点按需解析，避免本地 URL 被 Markdown parser 二次编码。

## 4. 四个版本的真实状态

版本定义在 `src/tools/rich-text-renderer/types.ts:688`，可见选项来自 `stores/store.ts:48`。

| 版本 | 当前行为 | 状态 |
|---|---|---|
| V1 `v1-markdown-it` | markdown-it 解析为 AST，再做稳定/待定区增量更新 | 可选，但标记过时 |
| V2 `v2-custom-parser` | 自研 Tokenizer + CustomParser + AST diff | 默认、推荐 |
| Pure `pure-markdown-it` | `md.render()` 全量输出 HTML，直接 `v-html` | 可选、基准用途 |
| V3 `hybrid-v3` | 没有处理器实现 | disabled，占位 |

`useAstRenderer` 只把 V1/V2 视为 AST 模式。任何其他枚举值都落到 Pure 分支，因此如果绕过设置 UI 强行写入 `hybrid-v3`，当前行为不是 V3，而是 Pure Markdown-it。

当前也没有 renderer registry。版本切换是 `createProcessor()` 内的固定 `switch`，新增真正的渲染器需要改入口类型、元数据列表、处理器创建逻辑和设置兼容层。

## 5. V2 解析与 Patch

### 5.1 Tokenizer 和 Parser

核心文件：

- `parser/Tokenizer.ts`：Sticky RegExp 词法分析；
- `parser/tokenizer.worker.ts` / `tokenizerService.ts`：Worker 调度；
- `core/CustomParser.ts`：Token 到 AST；
- `core/StreamProcessorV2.ts`：稳定区、待定区、diff 和生命周期。

Tokenizer 对 `code`、`pre`、`script`、`style` 等采用 raw mode，避免内部符号继续被当 Markdown。V2 AST 不只表达标准 Markdown，还包含：

- `llm_think`；
- `action_button`；
- `session_variable`；
- `vcp_tool`、`vcp_role`、`vcp_daily_note`；
- `html_block`、`html_inline`、`generic_html`；
- Mermaid、KaTeX、媒体和 GitHub Alert。

### 5.2 稳定区与待定区

`MarkdownBoundaryDetector` 查找安全切分点：稳定区尽可能复用旧 AST，末尾待定区每轮重解析。完整新树由两者合并，再与旧树统一 diff。

这个统一 diff 很重要：节点从 pending 迁移为 stable 时保留 ID，避免 Vue 将其当新节点重建，进而减少动画重播、折叠状态丢失和代码编辑器重挂载。

处理器忙时不会并发解析每个 delta，而只保存最新 `pendingBuffer`；本轮完成后直接处理最新快照，中间态可丢弃。

### 5.3 Patch 状态层

`useMarkdownAst.ts` 用 `shallowRef<AstNode[]>` 保存根树，支持 8 类 Patch：

- `text-append`；
- `set-prop`；
- `replace-node`；
- `insert-after` / `insert-before`；
- `remove-node`；
- `replace-children-range`；
- `replace-root`。

Patch 入队后由 rAF 检查 `throttleMs`，默认聊天配置为 80ms。flush 前合并连续的同节点 `text-append`，应用时沿 nodeMap 路径做不可变更新，未变化分支保留引用。

源码注释仍称“rAF + setTimeout 混合”，但实际调度只启动 rAF；`timeoutHandle` 是未使用的历史字段。

## 6. 节点渲染层

`components/AstNodeRenderer.tsx` 递归分派 AST：

| AST | 主要组件/行为 |
|---|---|
| text/strong/em/link/inline_code | 对应轻量 Vue 节点 |
| paragraph/heading/list/table/blockquote/alert | 结构化块组件 |
| code_block | CodeMirror 源码 + 可选 HTML/SVG iframe 预览 |
| mermaid | 动态导入 Mermaid，交互查看器 |
| katex_* | `KatexRenderer` |
| llm_think | `LlmThinkNode` |
| image/video/audio | 专用媒体节点和资产解析 |
| generic_html | 动态 HTML 标签组件 |
| style | 特判为 `StyleNode`，做 CSS 加前缀 |
| action_button | 通过 llm-chat registry 间接触发动作 |
| vcp_* | 专用 VCP UI |
| 未知类型 | 可见 warning fallback |

代码块固定使用 CodeMirror，并通过 IntersectionObserver 延迟实例化；Mermaid 也是动态 import。图片列表从 AST 节流提取，用于图片查看器上下张导航。

## 7. HTML 处理与隔离模型

### 7.1 V2 普通 HTML

V2 根据 HTML 在 AST 中的形态采用不同处理方式：

- `HtmlInlineNode` 使用 DOMPurify 白名单；
- `HtmlBlockNode` 使用 DOMPurify，但显式允许 `iframe`、表单、`style` 和较多 SVG；
- `GenericHtmlNode` 动态创建标签，默认拦截 script/style/iframe/form 等危险标签，删除 `on*` 属性和 `javascript:` URL，并过滤 fixed/sticky 等部分内联 CSS；
- `StyleNode` 用正则给选择器加作用域前缀，属于软隔离，不是 Shadow DOM 或浏览器安全边界。

`LinkNode.vue` 自身不做 URL scheme 过滤，只添加 `noopener noreferrer`，因此链接安全性依赖上游 parser。完整的防护边界由 parser 分类、节点局部过滤和 CSS 软隔离共同构成。

### 7.2 Pure Markdown-it 分支

`RichTextRenderer.vue:385` 创建 markdown-it 时设置 `html: true`，输出在模板第 27 行直接进入 `v-html`，没有 DOMPurify。`<script>` 经 innerHTML 通常不会直接执行，但事件属性、危险 URL、iframe/资源加载等仍可构成注入面。

Pure 分支的定位是基准对照，但它同时出现在聊天设置的可选列表中。横向比较时应把它与 V2 分开看待，因为两者的增量能力和 HTML 信任模型均不同。

### 7.3 HTML 交互预览环境

`HtmlInteractiveViewer.vue:133` 使用：

```html
<iframe
  :srcdoc="srcDoc"
  sandbox="allow-scripts allow-same-origin allow-forms allow-popups allow-modals"
></iframe>
```

预览器允许脚本、同源、表单、弹窗和模态框。日志、错误、鼠标活动和高度通过 `postMessage` 回传；内容稳定性检查和 1 秒节流用于减少流式阶段反复重载 iframe。

`srcdoc` 同时获得 `allow-scripts` 与 `allow-same-origin` 后，模型生成脚本可以访问同源 `window.parent` DOM。该 iframe 具备嵌入式小应用的运行能力，不构成强隔离的文档预览环境。

它所在的宿主环境还具有以下特征：

- `src-tauri/tauri.conf.json:15`：主窗口 CSP 为 `null`；
- `src-tauri/capabilities/default.json`：窗口匹配 `*`，文件读写 scope 多处为 `**`，并允许任意 HTTP(S)/WS(S) fetch；
- iframe CSP 即使在“禁止外部资源”模式下仍允许 `'unsafe-inline'`、`'unsafe-eval'` 和同源 script；
- “允许外部资源”模式的 CSP 基本放开所有来源。

至少可以确认 parent DOM 并未形成安全隔离。模型脚本能否在当前 WebView2/Tauri v2 组合中直接复用 `window.__TAURI_INTERNALS__` 调用命令，仅凭静态源码不能完全确认，需要真实运行时验证。

从设计分类看，AIO 选择的是“高能力 iframe + CSP 开关 + Tauri 宿主权限”的组合。与采用 opaque-origin sandbox、独立低权限 WebView，或完全禁止模型脚本的项目相比，它提供更强的交互展示能力，也引入更大的信任面。

## 8. 性能与长会话策略

### 已实现

- 流式显示与持久化分流；
- `StreamController` rAF 平滑输出，VCP 协议边界会强制 flush；
- 稳定 AST 引用复用、pending 最新值覆盖；
- Patch 80ms 节流和 text append 合并；
- `shallowRef` + 不可变路径更新；
- CodeMirror 延迟挂载、Mermaid 动态加载；
- 旧 HTML preview 按消息深度冻结，默认只保持最近 5 条活跃；
- 不可见消息冻结 Agent 样式/think rules，避免全列表配置更新；
- 消息元素使用 `content-visibility: auto` 和 `contain-intrinsic-size: auto 500px`；
- ResizeObserver 维护底部锁定；组件卸载主动释放 AST、iframe、Worker/控制器引用。

### 护栏阈值

V2 当前常量为：

- 单次解析上限 1,000,000ms；
- 单次迭代上限 6,000,000ms；
- buffer 上限 50MB；
- 边界停滞 10,000 轮；
- AST 节点上限 10,000,000。

这些数值表明，护栏用于防止极端失控，没有维持固定的交互延迟预算。横向比较时可将其归为灾难熔断机制，而非严格的资源配额。

### 列表采用渲染跳过而非窗口化

`MessageList.vue` 对 `messages` 全量 `v-for`，只用 CSS `content-visibility` 跳过离屏绘制。设置中的 `virtualListOverscan` 只有默认值、类型和 UI，消息列表运行时没有读取它。

这种列表策略有三个直接结果：

- DOM 节点、Vue 组件实例、watcher 和大部分 JS 状态仍常驻；
- overscan 滑块当前无效果；
- `content-visibility` 对绘制有帮助，但不等价于 windowing/virtualizer。

`virtualListOverscan` 的命名和 UI 暗示了 windowing，但当前实现更准确的描述是“全量组件常驻 + 离屏绘制跳过”。这是理解其长会话内存模型时的重要区别。

## 9. 桌面端与移动端使用不同引擎

移动端文件：

- `mobile/src/tools/rich-text-renderer/RichTextRenderer.vue`
- `mobile/src/tools/llm-chat/components/MessageContent.vue`

移动端使用 `marked.lexer()` 得到 token，再由同一个 Vue 组件递归渲染。支持标题、段落、列表、表格、代码、链接、图片和基础 HTML；代码只是 `<pre><code>`，没有 CodeMirror、AST Patch、VCP 节点、Mermaid/KaTeX、样式系统、正则管线或 stream source。

`isStreaming` prop 当前只参与类型/调用，没有改变解析或渲染策略。每次 `message.content` 变化都会重新 lexer 整段内容。

移动端 `html` token 在第 194 行直接 `v-html="token.text"`，没有 DOMPurify；链接也直接绑定 `token.href`。其功能少于桌面 V2，HTML 信任模型则更接近桌面 Pure 分支。

## 10. 交互式测试页与自动化覆盖

前述源码之外，AIO Hub 为渲染器维护了专门供人工操作的测试工具。测试能力必须拆成“交互式验证设施”和“无人值守自动回归”两部分评价；只统计 `*.test.ts` 会明显低估当前的开发调试能力。

### 10.1 桌面端 RichTextRenderer Tester

`rich-text-renderer.registry.ts` 将 `RichTextRendererTester.vue` 作为正式开发工具注册：

```text
工具名：富文本渲染测试
路由：/rich-text-renderer-tester
分类：开发工具
说明：测试 Markdown 富文本渲染，支持流式输出模拟
```

工具注册会被 `services/auto-register.ts` 的 `import.meta.glob("../tools/**/*.registry.ts")` 扫描，并出现在默认工具顺序中。这不是仓库外的临时 demo，而是应用内可进入的调试页面。

测试页直接挂载生产 `RichTextRenderer.vue`，而不是复制一份简化 renderer。它提供以下人工验证能力：

- 在 V1、V2 和 Pure Markdown-it 三个已启用版本间切换；
- 选择 Agent 并注入与聊天一致的 `currentAgent` 上下文，验证 `agent-asset://` 等资产解析；
- 使用 26 组共享预设，覆盖基础 Markdown、长文本/长代码、V2 parser、HTML 嵌套与换行、脚本交互、Canvas 游戏、Mermaid、KaTeX/MathJax、思考节点、Action Button、复杂混排、主题变量和样式隔离等场景；
- 立即渲染或构造真正的 `StreamSource`，经项目 token calculator 按所选 tokenizer 切分，失败时才退回字符流；
- 调整首包延迟、目标 Tokens/s、单次 Token 数和发包延迟波动，并用累计时间债务补偿保持平均速度；
- 独立切换 StreamController 平滑、AST 更新节流、节流间隔、高频日志和 safety guard；
- 模拟 `firstTokenTime`、`requestEndTime`、`tokensPerSecond` 等 generation metadata；
- 以颜色显示 `data-node-status=stable/pending`，实时查看生产 renderer 暴露的 AST；
- 强制 CodeMirror 停留在 `PreCodeNode` fallback，编辑 Markdown 样式和聊天正则；
- 在 renderer 外放置“样式逃逸检测区”，人工观察模型 CSS 是否越界；
- 使用 split、input-only、preview-only 和 curtain 布局观察流式原文/结果交接；
- 导出配置、原文、HTML、规范化纯文本、节点状态和样式配置组成的对比报告；
- 截取预览区域，并复制或保存图片，便于提交可复现的视觉问题。

因此 AIO 不仅具有“能打开渲染结果”的 playground，还提供了针对 stable/pending、网络波动、parser 版本、样式隔离和 Agent 上下文的专用诊断面。它对开发期人工探索、视觉验收和问题复现很有价值。

需要注意，对比报告中的“文本匹配”基于 Markdown/HTML 字符串清理和规范化后的字符长度差，而不是结构化语义 diff；截图、逃逸检测和复杂交互也都需要人工判断。预设是输入语料库，并没有声明期望 AST/DOM 快照或 pass/fail oracle。

测试角色 UI 还提供 User Profile 选择，但 `RichTextRendererTester.vue` 当前只在 `profileType === "agent"` 时构造 `currentAgent`，所选 User Profile 没有进入 renderer 的 props 或 provide context，也不会自动加载该 Profile 的样式。因此这部分目前更像未接完的测试入口，不能据此声称测试页已覆盖 User Profile 专属行为。

### 10.2 移动端测试页

移动端也注册了独立工具页：

- registry 路由为 `/tools/rich-text-renderer`；
- `TesterView.vue` 提供编辑、预览、帘幕和调试四个视图；
- 通过 `@shared` 复用桌面端同一组 26 个预设；
- 可配置流速、首包延迟和波动范围，显示 Token、TPS、耗时和字符统计；
- 可复制对比报告、渲染 HTML 和 AST JSON。

移动端没有引入桌面的 token calculator/WASM 分词依赖，使用中文按字、英文按单词/空格切分的轻量算法。它也不创建桌面的 `StreamSource`，而是不断追加 `currentContent`，触发移动 renderer 对累计全文重新 `marked.lexer()`。调试抽屉中的 AST 同样来自页面自己的 `marked.lexer(currentContent)`。因此移动测试页验证的是移动端真实的累计 content 更新路径，但不能用来验证桌面 V2 CustomParser 的 AST/Patch 行为。

### 10.3 自动化测试边界

与核心渲染器直接相关的自动测试目前主要包括：

- `useMarkdownAst.test.ts`：同一 batch 内路径索引和 Patch 操作；
- `parseVcpRole.test.ts`：VCP 工具结果/摘要去重；
- `useStreamingMessageSources.test.ts`：buffer replay、delta 和 complete。

在已有人工测试台之外，以下关键链路仍未看到可在 CI 中无人值守判定结果的直接自动测试：

- `RichTextRenderer` 静态、流式和结束交接；
- V2 stable/pending 边界和异步 latest-buffer 语义；
- 26 组预设的期望 AST/DOM/截图回归基线；
- HTML/URL/CSS sanitizer 攻击用例；
- iframe sandbox 与 Tauri capability 隔离；
- renderer 版本切换和非法/未来版本兼容；
- 长消息、长列表和高频流 benchmark 阈值；
- 移动端 HTML 安全与流式最终一致性。

现有证据表明：**AIO 的人工验证和诊断工具覆盖面较广，自动回归仍主要覆盖底层操作。** 测试页降低了复现和人工验收成本，但不能替代 CI 中确定性的 parser、sanitizer、stream lifecycle 和性能回归测试。

## 11. 横向比较坐标

为了与其他项目的消息渲染调查使用同一视角，可以把 AIO Hub 概括为下表：

| 比较维度 | AIO Hub 当前实现 |
|---|---|
| 消息数据模型 | 树形 `ChatMessageNode`；正文 string，附件/reasoning/tool metadata 半结构化 |
| 消息级分派 | Compression / Tool / Normal 三类列表组件 |
| 正文中间表示 | V2 自研 AST；V1 由 markdown-it 转 AST；Pure 无中间表示 |
| 流式输入 | 每 node replayable `StreamSource`，与持久化 buffer 分流 |
| 增量粒度 | stable/pending 区 + AST diff + 8 类 Patch |
| 更新调度 | StreamController rAF 平滑 + Patch rAF/80ms 节流 |
| 推理表示 | provider reasoning metadata 与正文 `<think>` AST 两条路径 |
| 工具表示 | role=tool 专用消息与正文 VCP AST 节点两条路径 |
| 富内容能力 | HTML、CodeMirror、Mermaid、KaTeX、媒体、VCP、交互按钮 |
| HTML 模型 | V2 节点局部净化；Pure/mobile 直接 `v-html`；代码块可执行 iframe |
| 样式能力 | 全局 + Agent + User Profile CSS 变量，模型 `<style>` 软作用域化 |
| 资产协议 | Agent 资产、附件占位符、Tauri asset、本地文件和 VCP URL 统一解析 |
| 长列表策略 | 全量 Vue 组件常驻，`content-visibility` 跳过离屏绘制，无消息 windowing |
| 重型节点策略 | CodeMirror 延迟挂载、Mermaid 动态 import、旧 iframe 冻结 |
| 扩展方式 | 固定 AST union、组件映射和 renderer enum；没有消息渲染器 registry |
| 桌面/移动一致性 | 两套不同引擎；桌面能力远高于移动端 |
| 人工验证设施 | 桌面/移动内建测试页；26 组共享预设；流式、AST、样式隔离、对比报告和截图诊断 |
| 自动测试重心 | Patch 基础操作、VCP 个别解析、StreamSource 生命周期；集成与安全回归仍不足 |

### 设计取舍

AIO Hub 让渲染器直接理解业务协议：VCP、思考标签、资产 URL、交互按钮和 Agent 样式都深入 AST 与节点层。这能直接适配上述聊天功能，但 renderer 与 llm-chat、agent-manager、vcp-connector 之间的耦合也明显高于通用 Markdown 组件。

它的流式方案以“**保留稳定 Vue 子树**”为中心：先让 StreamSource 隔离高频数据，再用 stable/pending 和 Patch 保存节点身份。与每个 chunk 全量 Markdown 转 HTML、结构化 message parts 直接渲染或仅在文本层做平滑播放相比，这套方案把更新范围收缩到仍不稳定的节点。

在长会话方面，它更重视重型内容冻结和浏览器绘制跳过，而没有选择消息 DOM windowing。对应的收益是滚动定位、选择状态和复杂节点生命周期较简单；代价是组件及响应式状态仍随消息总量增长。

## 12. 关键文件索引

| 领域 | 文件 |
|---|---|
| 消息列表 | `src/tools/llm-chat/components/message/MessageList.vue` |
| 普通消息壳 | `src/tools/llm-chat/components/message/ChatMessage.vue` |
| 正文适配 | `src/tools/llm-chat/components/message/MessageContent.vue` |
| 工具消息 | `src/tools/llm-chat/components/message/ToolCallMessage.vue` |
| 流式入口 | `src/tools/llm-chat/composables/chat/useChatResponseHandler.ts` |
| Replayable source | `src/tools/llm-chat/composables/chat/useStreamingMessageSources.ts` |
| 渲染器入口 | `src/tools/rich-text-renderer/RichTextRenderer.vue` |
| V2 流处理 | `src/tools/rich-text-renderer/core/StreamProcessorV2.ts` |
| 自研 parser | `src/tools/rich-text-renderer/core/CustomParser.ts` |
| Tokenizer | `src/tools/rich-text-renderer/parser/Tokenizer.ts` |
| AST/Patch 类型 | `src/tools/rich-text-renderer/types.ts` |
| Patch store | `src/tools/rich-text-renderer/composables/useMarkdownAst.ts` |
| 节点分派 | `src/tools/rich-text-renderer/components/AstNodeRenderer.tsx` |
| 桌面人工测试页 | `src/tools/rich-text-renderer/components/RichTextRendererTester.vue` |
| 测试页配置 | `src/tools/rich-text-renderer/components/tester/TesterConfigSidebar.vue` |
| 测试预设注册 | `src/tools/rich-text-renderer/config/presets.ts` |
| HTML 预览 | `src/tools/rich-text-renderer/components/HtmlInteractiveViewer.vue` |
| HTML 净化 | `src/tools/rich-text-renderer/components/nodes/HtmlBlockNode.vue` |
| CSS 软隔离 | `src/tools/rich-text-renderer/utils/cssUtils.ts` |
| 默认设置 | `src/tools/llm-chat/config/defaultSettings.ts` |
| 设置 UI | `src/tools/llm-chat/components/settings/settingsConfig.ts` |
| Tauri 安全配置 | `src-tauri/tauri.conf.json`, `src-tauri/capabilities/default.json` |
| 移动端渲染器 | `mobile/src/tools/rich-text-renderer/RichTextRenderer.vue` |
| 移动端人工测试页 | `mobile/src/tools/rich-text-renderer/views/TesterView.vue` |
