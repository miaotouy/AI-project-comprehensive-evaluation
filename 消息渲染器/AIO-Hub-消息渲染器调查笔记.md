# AIO Hub 消息渲染器调查笔记

> 调查对象：`https://github.com/miaotouy/aio-hub`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`03cf4b6e028d0e23d5447a7c0cd7678aab07af3f`（分支：`dev`）
>
> 调查方式：只读核对聊天适配层、富文本运行时、相关测试与两源码快照差异；未运行服务、视觉测试或性能基准
>
> 调查范围：消息输入模型、流到 UI、行壳与内容回收、Markdown/HTML/VCP、媒体和文本材料、交互与扩展；桌面为主，移动端单独核对引擎与内容边界
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

消息显示由聊天领域和富文本领域分工：前者维护活动路径、消息壳、工具卡、附件、推理、翻译与操作；后者把字符串持续解析为 AST，通过增量 Patch 更新 Vue 树。桌面默认自研 V2 解析器，移动端则使用 marked token 递归组件，两端不能互换推定能力。

- 正文高频流源与节点低频写回分开；provider reasoning 另走 metadata，正文 think 标签则在 AST 内解析。
- 线性列表全量保留行壳，正文显示树按阅读区/页面停用回收，静态离屏内容可延迟首次解析；长正文还按顶层块回收，代码查看器有独立视口生命周期。行壳常驻与正文组件常驻是两个不同判断。
- 连续紧凑布局以身份和父子连续性分组，保留每条消息 ID 和操作，只在展示头、状态和统计脚注做合并。
- VCP 可作为正文 AST，也可被上游拆成独立工具消息；结果值保持字面内容，避免结果里的 HTML 或协议示例被二次执行解释。
- HTML/SVG 代码块有可执行脚本的 iframe 预览；普通 HTML AST、Pure 模式和移动端原始 HTML 各有不同边界，不能用一个“HTML 已净化”概括。
- 流式装饰可选星屑、几何、花瓣、扫描和水墨等样式，采用原生文字范围着色和独立 Canvas，跟随生成、可见宿主与 reduced-motion 生命周期。视觉观感及性能尚未实测。

## 总体渲染链

```text
模型响应回调
  -> 正文 StreamSource（高频 delta，可重放）
  -> 节点正文/metadata 批量写回（同步与持久化交接）
  -> MessageList：活动路径、阅读区、行高、滚动锚定、只读作用域
  -> MessageRow：普通/工具/压缩分派 + 卡片/气泡/紧凑布局
  -> MessageContent：附件/文本材料、独立推理、正文、译文
  -> RichTextRenderer：预处理 + 流平滑 + V1/V2 解析 / Pure HTML
  -> stable/pending AST -> diff/Patch -> 节点组件
  -> 阅读区显示树、长消息块与代码查看器分别管理挂载
```

聊天入口、Composer、搜索工作流和消息操作见[Chat UI 笔记](<../Chat UI/AIO-Hub-ChatUI调查笔记.md>)；请求和数据持久化分别见[请求笔记](<../对话请求与上下文/AIO-Hub-对话请求与上下文调查笔记.md>)、[会话笔记](<../会话与消息管理/AIO-Hub-会话与消息管理调查笔记.md>)。具有独立身份和版本生命周期的画布见[生成运行时笔记](<../生成式输出与运行时/AIO-Hub-生成式输出与运行时调查笔记.md>)。

## 1. 消息模型、行壳与分组

### 1.1 字符串正文和结构化元数据

[消息类型](<../../aio-hub/src/tools/llm-chat/types/message.ts>)通过父子 ID 和活动叶子表达树，正文仍以单一字符串为主，没有把全部内容改成统一 parts 数组。附件、文本材料和 Knowledge 引用有独立字段；metadata 保存推理、翻译、工具请求/结果、图像预览、错误、压缩和生成身份等结构。

消息状态包含生成、等待、排队、完成和错误；展示映射进一步识别手动停止、队列停止和异常空回复。正文仍在增长与任务仍在运行通过 store/executor 状态共同判断，不能只看节点枚举。[状态映射](<../../aio-hub/src/tools/llm-chat/utils/messageStatus.ts>)负责中文标签和显示条件。

消息头的历史名称优先用快照；模型图标则优先用当前精确渠道 ID 与模型 ID 查到的模型配置，再退回快照和模型名图标匹配。这避免用渠道协议类型猜模型品牌，也意味着当前图标配置变更可影响历史显示；“名称和图标都始终快照优先”不符合现有路径。[消息头](<../../aio-hub/src/tools/llm-chat/components/message/MessageHeader.vue#L116-L161>)可直接复查。

### 1.2 列表先建行，再分派消息类型

[MessageList](<../../aio-hub/src/tools/llm-chat/components/message/MessageList.vue#L793-L827>)遍历活动路径，以消息 ID 为稳定 key，把行高、展示分组、只读和动作表交给行组件。内部再按压缩节点、工具角色、普通消息的顺序分派，见[MessageRow](<../../aio-hub/src/tools/llm-chat/components/message/MessageRow.vue#L137-L170>)。

普通消息由头、正文、操作栏、变量快照和统计组成；工具结果由专用工具卡承载。紧凑分组不拼接正文或替换节点：隐藏后续重复身份头，把当前活动状态提升到组首，末尾汇总统计；每条消息仍有单独锚点及可用操作。分组要求父子连续和身份一致，工具还需能关联到本组助手的请求，见[展示投影](<../../aio-hub/src/tools/llm-chat/utils/messagePresentation.ts#L98-L170>)。

### 1.3 统计与变量快照

[消息统计](<../../aio-hub/src/tools/llm-chat/components/message/MessageStatistics.vue#L14-L125>)按偏好显示字数、输入/输出 Token、缓存量和完成态性能数据；有本地正文 Token 时会用于输出展示，不能把脚注总数直接等同于上游原始总量。紧凑组尾另有聚合统计，详细口径由[组脚注](<../../aio-hub/src/tools/llm-chat/components/message/MessageGroupFooter.vue>)承担。

变量快照卡支持摘要、仅变更和按路径搜索；详情弹窗已独立，卡片与弹窗共用筛选状态和路径复制逻辑。变量值按旧值→新值与操作标记呈现，未变项使用单值。[详情组件](<../../aio-hub/src/tools/llm-chat/components/message/MessageVariableSnapshotDialog.vue#L26-L99>)把视图状态作为显式输入，避免弹窗另建一份不同步的过滤条件。

## 2. 流式数据到可见 UI

### 2.1 高频流源与低频节点更新

[流源管理](<../../aio-hub/src/tools/llm-chat/composables/chat/useStreamingMessageSources.ts>)按节点维护可重放源，新订阅者在 microtask 中收到已有 buffer，后续 delta 广播给订阅者；完成后延迟释放，为组件重挂载交接留出窗口。该源属于当前前端运行时，分离窗口经流式事件在本地重建自身源。

[响应处理器](<../../aio-hub/src/tools/llm-chat/composables/chat/useChatResponseHandler.ts>)先把正文 delta 送进显示源，再批量写回节点与同步缓冲。持久化消息、跨窗口事件和界面绘制有各自频率，不能统称“每 Token 落库并重绘”。结束时完成流源并交接最终正文。

[正文适配](<../../aio-hub/src/tools/llm-chat/components/message/MessageContent.vue#L333-L413>)只在生成且执行器活跃时使用流源；进入生成态改变一次渲染 key，让旧静态实例转为流输入，结束时不再整体换 key，以保留 iframe 和稳定节点。

### 2.2 推理与预处理

provider reasoning delta 合并到推理 metadata，再由顶层思考块承载另一个富文本实例；正文内 think 标签由解析器生成思考 AST。两条链独立，时间、折叠和流式状态也有各自输入。

正文渲染先规范换行、应用仅显示阶段正则，再处理资产和 HTML 形态。流源路径隐藏末尾未闭合 HTML 标签片段，避免半截标签先画成文字；裸 DOCTYPE 页面包装成 HTML 代码围栏。AST 节点自行解析资源 URL，Pure 模式则全局替换后 render。预处理与静态配置重解析都复用同一结果，见[渲染器入口](<../../aio-hub/src/tools/rich-text-renderer/RichTextRenderer.vue#L84-L155>)与[内容预处理](<../../aio-hub/src/tools/rich-text-renderer/RichTextRenderer.vue#L497-L658>)。

Agent/User Profile 显示规则会先经过来源合并、角色/深度过滤和宏展开；预设展示消息在显示阶段展开宏，普通已发送历史正文沿用已有文本。规则只改变当前渲染结果，其输入不直接改写存储正文。[正文适配层](<../../aio-hub/src/tools/llm-chat/components/message/MessageContent.vue>)负责这些上游差异。

## 3. Markdown 引擎、稳定区与 Patch

### 3.1 可选版本的真实执行

| 版本 | 执行方式 |
|---|---|
| V1 | markdown-it 到 AST，保留稳定/待定区机制；界面标记过时 |
| V2 | 自研 Tokenizer、CustomParser、稳定区与增量 diff；桌面默认 |
| Pure | markdown-it 全量 HTML，经 v-html 显示 |
| V3 | 元数据占位且禁用，尚无专用处理器 |

[类型定义](<../../aio-hub/src/tools/rich-text-renderer/types.ts>)和[渲染器选择](<../../aio-hub/src/tools/rich-text-renderer/RichTextRenderer.vue>)使用固定分派；只有 V1/V2 进入 AST 路径，其余值走 Pure。因此绕过界面写入 V3 值不会获得混合引擎。当前未在这些入口找到运行时第三方渲染器注册表，新增版本需同时改类型、元数据、处理器创建和设置兼容。

### 3.2 V2 的持续解析

[StreamProcessorV2](<../../aio-hub/src/tools/rich-text-renderer/core/StreamProcessorV2.ts>)在安全边界前保留稳定区，对尾部待定区重复解析；代码围栏、表格、链接、KaTeX、HTML 属性和 VCP 块参与边界判断。等待中的解析只保留最新输入，避免重叠解析累计过期结果；完成态收口尾部。

[Tokenizer](<../../aio-hub/src/tools/rich-text-renderer/parser/Tokenizer.ts>)负责词法和 raw 内容模式，[CustomParser](<../../aio-hub/src/tools/rich-text-renderer/core/CustomParser.ts>)生成 Markdown、HTML、思考、VCP、变量和动作按钮等 typed AST。稳定节点身份与不可变子树引用用于差异计算，Patch 再由[AST 状态适配](<../../aio-hub/src/tools/rich-text-renderer/composables/useMarkdownAst.ts>)按帧/节流批量应用，文本追加可合并。

分词通过共享 Worker，但传输会话按解析所有者隔离。追加请求只发送文本尾段，响应可复用 token 公共前缀并给长字段传范围更新；接收时检查修订号和前缀合法性，不匹配则释放会话。完成和重新解析按代次隔离，避免旧 Worker 结果污染新树。[传输服务](<../../aio-hub/src/tools/rich-text-renderer/parser/tokenizerService.ts#L41-L175>)与[增量编码](<../../aio-hub/src/tools/rich-text-renderer/parser/tokenizerTokenDelta.ts>)给出了实际协议。

### 3.3 模糊恢复与护栏

思考标签闭合采用规范化和有限模糊匹配，闭合状态变化即使文本指纹未变也需更新思考节点。VCP 的 ESCAPE 内容会整体跳过，参数里的示例结束标记不应中断外块；坏块遇后续同级起点可恢复扫描。仅显示侧的模糊围栏恢复有单独开关，接受启发式边界需要剩余字段能完整收敛，保留原文及诊断，不改变真正工具执行解析。证据见[共享块边界](<../../aio-hub/src/utils/vcpBlockBoundary.ts>)与[显示恢复器](<../../aio-hub/src/tools/rich-text-renderer/parser/vcpFenceRecovery.ts#L54-L125>)。

V2 护栏约束缓冲、解析时长和停滞次数，开关可配置。当前单次解析和迭代时长上限分别是 1,000,000ms 与 6,000,000ms，缓冲约 50MB、边界停滞 10,000 次；这些是失控保护，不能视为低延迟保证。[护栏定义与调用](<../../aio-hub/src/tools/rich-text-renderer/core/StreamProcessorV2.ts#L594-L650>)可复查。

## 4. 阅读区、回收与滚动

### 4.1 保留行壳，按阅读区显示正文

列表仍对所有活动路径消息建立行壳，使用 content-visibility 和行高缓存控制离屏绘制；行高结合段落预估及有界整行实测，布局修订时重新测量。[行高管理](<../../aio-hub/src/tools/llm-chat/composables/ui/useMessageHeights.ts>)不等同于 TanStack 消息窗口化。

[阅读区](<../../aio-hub/src/tools/llm-chat/composables/ui/useMessageReadingArea.ts#L18-L89>)以视口上下各 600px 为预热区，从有序行壳二分定位开始范围，并保留最后一行。正文向这里登记；选区或焦点保护可扩大显示范围。静态离屏正文尚未首次显示时可延迟 parser 初始化，已有显示树离开阅读区 300ms 后可卸载，只保留几何、源文本和已拥有的解析状态。[显示控制](<../../aio-hub/src/tools/rich-text-renderer/composables/useRendererDisplay.ts#L89-L165>)与[延迟解析入口](<../../aio-hub/src/tools/rich-text-renderer/RichTextRenderer.vue#L552-L625>)共同确定此行为。

页面 KeepAlive 停用时，列表把宿主标为 inactive、停止观察和锚定；富文本显示子树可释放，解析器和流订阅的所有权仍留在外层。流式内容、打开的查看器、选区、焦点及含 iframe/媒体/表单/Canvas 等有状态嵌入会保护显示，避免盲目销毁交互现场。[显示保护条件](<../../aio-hub/src/tools/rich-text-renderer/composables/useRendererDisplay.ts#L111-L165>)是回收前提，不能把离屏一概写为“必销毁”。

### 4.2 视图状态与长正文块级回收

渲染器用稳定 AST ID 保存少量折叠、源码/预览等视图字段，回收时不保存 DOM、组件实例或编辑器对象；重新挂载消费快照，并按新树裁剪无效节点。打开 Teleport 查看器会占用 display hold，直至查看器关闭。见[视图状态](<../../aio-hub/src/tools/rich-text-renderer/composables/useRendererViewState.ts#L40-L136>)。

至少 40 个顶层 AST 块的静态消息，还可在正文内部按视口外扩 700px、延迟 300ms 回收块。占位保留原标签、边距和实测尺寸，按块恢复状态；选区、焦点和有状态嵌入受保护，截图模式不启用此机制。见[块挂载控制](<../../aio-hub/src/tools/rich-text-renderer/composables/useRendererBlockMounting.ts#L29-L119>)。

代码查看器独立延迟创建 CodeMirror，离开视口后可销毁编辑器并回到轻量源码占位，保留滚动/选区等必要状态。代码、块、整条正文显示树是三个不同粒度的生命周期，见[源码查看器](<../../aio-hub/src/tools/rich-text-renderer/components/nodes/code-block/CodeMirrorSourceViewer.vue>)。

### 4.3 锚定与恢复

阅读历史时记录消息 ID 和视口内相对偏移，内容高度变化或分支切换后修正滚动；贴底阅读则由 ResizeObserver 和自动滚动偏好控制。恢复页面时先恢复锚点，正文异步高度到达后再次校正，避免只保存一个过时 scrollTop。见[滚动锚点](<../../aio-hub/src/tools/llm-chat/composables/ui/useMessageScrollAnchor.ts>)和[列表激活流程](<../../aio-hub/src/tools/llm-chat/components/message/MessageList.vue#L92-L112>)。

当前策略随总消息数保留行壳和部分响应式状态，但释放了大量重型显示树；内存、重绘次数、首屏延迟与长会话滚动性能仍需基准。设置中的 virtualListOverscan 在已读消息运行路径未见消费，不能以设置项存在声称消息列表采用固定窗口。

## 5. 结构化内容与消息内交互

### 5.1 AST 节点分派

[AstNodeRenderer](<../../aio-hub/src/tools/rich-text-renderer/components/AstNodeRenderer.tsx>)递归分派轻量文本、段落/列表/表格、代码、KaTeX、Mermaid、思考、HTML、媒体、VCP、动作按钮和会话变量；未知类型给可见 fallback。VNode 复用依赖节点引用和渲染上下文，不能只比较正文字符串忽略配置。

Mermaid 动态导入，流式以最新值窗口合并，仅末尾未完成行变化时可跳过排版，等待期间保留上次成功 SVG；生成 SVG 经专用净化后显示。KaTeX 有独立组件，代码块用 CodeMirror，HTML 自动预览和默认折叠变化会继续影响已挂载节点。入口见[Mermaid 节点](<../../aio-hub/src/tools/rich-text-renderer/components/nodes/MermaidNode.vue>)、[运行时](<../../aio-hub/src/tools/rich-text-renderer/utils/mermaidRuntime.ts>)与[SVG 净化](<../../aio-hub/src/tools/rich-text-renderer/utils/sanitizeMermaidSvg.ts>)。

### 5.2 两种工具结果显示路径

独立工具卡接收结构化工具元数据及正文；折叠时只做短摘要，展开才准备完整显示文本。首帧立即显示，后续流式更新以 100ms 最新值合并；完成态再格式化。超过 100,000 字符的结果正文走 CodeMirror 源码查看器，较短内容用 pre。见[结果显示调度](<../../aio-hub/src/tools/llm-chat/composables/ui/useToolResultDisplay.ts>)与[工具卡正文分派](<../../aio-hub/src/tools/llm-chat/components/message/ToolCallMessage.vue#L1215-L1283>)。

VCP 正文中的角色/工具返回批次仍能变为 AST。完整批次识别顶层结果封套和摘要，结果文字不再递归送 Markdown、HTML 或工具请求解析；同名同状态摘要可去重，未闭合批次显示未完成，无法识别则退回字面正文。[批次解析](<../../aio-hub/src/tools/rich-text-renderer/utils/vcpToolBatchDisplay.ts#L17-L65>)和[角色节点](<../../aio-hub/src/tools/rich-text-renderer/components/nodes/VcpRoleNode.vue#L18-L63>)说明历史正文路径；上游已拆出的 role=tool 消息用同一显示投影进入工具卡。

工具卡还有后台任务派遣链接、状态与预览渲染入口；审批操作显示与否由只读和业务权限条件共同决定，真实执行语义见工具笔记。

### 5.3 附件、文本材料、翻译与动作

资产附件按类型进入图片、音视频、文档和文件卡，显示导入/转换/失败等状态，媒体点击转全局查看器。AST 图片 URL 在节点解析，不重复改写整段 Markdown；图片列表按不可变子树缓存提取，保留重复项和顺序。见[资产卡](<../../aio-hub/src/tools/llm-chat/components/AttachmentCard.vue>)与[图片索引](<../../aio-hub/src/tools/rich-text-renderer/utils/astImageIndex.ts>)。

文本材料有独立卡片与编辑器，可预览、新建、编辑、展开原文；历史消息保存支持直接更新和编辑分支，并检查生成中/只读/并发修改条件。[文本材料](<../../aio-hub/src/tools/llm-chat/components/VirtualTextAttachments.vue>)与[历史消息写入门控](<../../aio-hub/src/tools/llm-chat/components/message/MessageContent.vue#L169-L208>)保留完整工作流交点，材料进入模型的转换由请求领域负责。

译文与原文各有富文本实例，可只显示其中之一或并排显示，并跟随可用宽度改变排布。动作按钮 AST 通过聊天 registry 发送消息、插入文本或复制，不是任意代码执行接口。见[正文布局](<../../aio-hub/src/tools/llm-chat/components/message/MessageContent.vue#L1349-L1455>)与[动作按钮](<../../aio-hub/src/tools/rich-text-renderer/components/nodes/ActionButtonNode.vue>)。

## 6. HTML、iframe 与可执行消息

### 6.1 三类桌面 HTML 路径

| 内容路径 | 承载边界 |
|---|---|
| AST 内联/块 HTML | 对应节点使用 DOMPurify 和各自允许集合 |
| 动态 HTML 标签与 style 节点 | 危险标签开关、事件/URL/部分 CSS 过滤；style 选择器加前缀属于软作用域 |
| Pure Markdown-it | html 开启，结果直接 v-html，没有经过上述 AST 节点净化 |

证据见[内联 HTML](<../../aio-hub/src/tools/rich-text-renderer/components/nodes/HtmlInlineNode.vue>)、[块 HTML](<../../aio-hub/src/tools/rich-text-renderer/components/nodes/HtmlBlockNode.vue>)、[动态 HTML](<../../aio-hub/src/tools/rich-text-renderer/components/nodes/GenericHtmlNode.vue>)与[CSS 处理](<../../aio-hub/src/tools/rich-text-renderer/utils/cssUtils.ts>)。不同开关和路径的边界不相同，本笔记仅解释内容承载，未作通用安全审计。

### 6.2 HTML/SVG 代码块预览

[HtmlInteractiveViewer](<../../aio-hub/src/tools/rich-text-renderer/components/HtmlInteractiveViewer.vue#L129-L140>)以 srcdoc iframe 承载 HTML/SVG，sandbox 包含脚本、同源、表单、弹窗和模态能力；预览可运行 Canvas 游戏、表单和 JavaScript 小应用。iframe 不是独立低权限 WebView，不能单凭“有 sandbox”断言其具备 opaque-origin 隔离。

外部脚本资源开关决定注入 CSP 的来源约束；日志、异常和高度通过消息回传宿主，流式内容约一秒合并刷新并保留尾随补交；通常检查 script 开闭数量稳定后提交，首次无旧预览且长度超过 100 字符时允许回退显示。旧预览可按消息深度冻结。见[CSP 与内容节流](<../../aio-hub/src/tools/rich-text-renderer/components/HtmlInteractiveViewer.vue#L295-L373>)。主应用 [Tauri 配置](<../../aio-hub/src-tauri/tauri.conf.json>)和[能力配置](<../../aio-hub/src-tauri/capabilities/default.json>)提供宿主权限背景，未实际测试跨边界访问。

因此当前已有消息内可执行应用表面；它与具有独立身份、版本和文件树的画布是不同生命周期。iframe 自动高度、主题变量注入、错误查看与复制构成内容消费的一部分，视觉、脚本副作用和平台降级仍需运行验证。

## 7. 流式装饰与动画生命周期

[聊天设置](<../../aio-hub/src/tools/llm-chat/components/settings/settingsConfig.ts#L705-L729>)提供流式文字效果，Agent 可选择继承或覆盖；截图强制关闭装饰。统一[设置映射](<../../aio-hub/src/tools/llm-chat/utils/richTextRendererSettings.ts#L22-L50>)把最终值传到正文、推理和译文渲染器，不能仅凭菜单项判断传播成功。

装饰不改写存储正文，也不通过包裹每个字符实现。控制器观察追加文字，为新增原生 Text 范围着色，并在独立 Canvas 绘制扫光和粒子；CSS Highlight 不受支持时原生字形着色降级。重解析或重挂载的旧文字不应全部重播，任务有待处理文本、粒子与范围数量上限。实现见[装饰控制器](<../../aio-hub/src/tools/rich-text-renderer/utils/streamStardust.ts#L41-L150>)与[原生文字着色](<../../aio-hub/src/tools/rich-text-renderer/utils/streamTextTint.ts#L22-L125>)。

启用条件同时检查效果选择、动画开关、显示宿主和流式状态；流结束后收尾，禁用、停用或卸载释放控制器，尊重 prefers-reduced-motion。历史静态消息不为装饰订阅媒体偏好变化。普通节点入场动画在流结束和回收恢复后停用，避免整篇旧文重新入场。见[装饰生命周期](<../../aio-hub/src/tools/rich-text-renderer/composables/useStreamStardust.ts#L18-L65>)与[渲染器接线](<../../aio-hub/src/tools/rich-text-renderer/RichTextRenderer.vue#L434-L454>)。

同源 iframe 预览也能接装饰：重载前记录已显示文字，新文档 load 后重新接管 body，仅标识新增内容；若导航越出可访问同源文档则退出，不调整原有 sandbox。见[HTML 装饰桥接](<../../aio-hub/src/tools/rich-text-renderer/composables/useHtmlStreamStardust.ts>)。以上确认实现路径，粒子效果、视觉舒适性和低端 WebView 帧率本轮未实测。

## 8. 移动端为独立引擎

[移动渲染入口](<../../aio-hub/mobile/src/tools/rich-text-renderer/RichTextRenderer.vue#L1-L109>)用 marked lexer 和递归组件，不共享桌面 AST/Patch、Worker 和稳定/待定区。中间流按 80ms 合并，首个内容、清空和完成立即提交；递归 token 路径不再自行启动顶层流定时器。

它有独立思考、Alert、KaTeX、Mermaid、VCP、代码和受管媒体组件。原始 Markdown 保持不变，资源解析在具体节点 URL 上执行，避免同一 URL 二次转换。原始 HTML token 使用 pre 文本展示，未进入 v-html；链接和图片有协议/来源限制，受管媒体由统一预览处理。[HTML token 分支](<../../aio-hub/mobile/src/tools/rich-text-renderer/RichTextRenderer.vue#L494-L519>)可复查。桌面 Pure 分支的 HTML 行为不能套用到移动端。

## 9. 测试与诊断工具的证据边界

桌面[测试工作台](<../../aio-hub/src/tools/rich-text-renderer/components/RichTextRendererTester.vue>)是正式注册工具，直接驱动生产 renderer，支持静态/流源、版本选择、Agent 资产、AST 与稳定区观察、样式覆盖、原文/预览帘幕、流速/延迟及节流/平滑/护栏配置；[共享预设](<../../aio-hub/src/tools/rich-text-renderer/config/presets.ts>)包含 Markdown、HTML/Canvas、VCP、代码、公式和混合内容。报告与截图便于人工复现，但预设本身不自动构成 pass/fail oracle。

移动[测试页](<../../aio-hub/mobile/src/tools/rich-text-renderer/views/TesterView.vue>)复用预设，通过累计 content 驱动自身 marked 引擎；它的 AST 调试来自页面 token，不能验证桌面 V2 Patch。仓库另有 CommonMark 对照脚本，属于标准解析辅助证据，不能替代所有自定义节点行为。

现有自动测试覆盖 parser、流边界、AST 更新、Worker 会话、块回收、iframe 生命周期、Mermaid、代码查看器、文字节点和流式装饰。本轮未执行这些测试，也未以文件数量或测试存在性推断全部通过；关键入口包括[renderer 生命周期测试](<../../aio-hub/src/tools/rich-text-renderer/components/__tests__/RichTextRenderer.lifecycle.test.ts>)、[块回收测试](<../../aio-hub/src/tools/rich-text-renderer/composables/__tests__/useRendererBlockMounting.test.ts>)、[Worker 测试](<../../aio-hub/src/tools/rich-text-renderer/parser/__tests__/tokenizerService.test.ts>)和[装饰测试](<../../aio-hub/src/tools/rich-text-renderer/utils/__tests__/streamStardust.test.ts>)。

## 10. 设计取舍、扩展与未验证事项

渲染器围绕稳定节点身份组织：高频流先隔离，解析保留稳定区，增量 Patch 缩小重建范围，再以阅读区和多级挂载回收控制重型显示树。结果是源文本、解析状态、显示状态和持久化相互独立，调查性能时需明确测的是哪一层。

新增节点要同时确认类型/props、parser、AST 分派、交互状态快照和承载边界；新 renderer 版本还需修改入口固定分派。没有把所有行为统一成运行时插件，业务动作和资源协议仍与聊天、Agent、VCP 领域接合。

尚未验证：

- 新旧布局、紧凑分组、变量弹窗、工具巨型正文与提问定位的真实阅读体验。
- 回收后折叠/源码/预览/选区恢复、复杂嵌入保护、跨窗口重连的端到端表现。
- 长会话内存、首屏解析、Worker 高频传输、滚动抖动和装饰帧率；静态阈值不代表性能达标。
- HTML/CSS/URL 过滤、iframe sandbox/CSP 与 Tauri capabilities 的完整安全验证。
- 平台媒体、剪贴板、键盘和读屏行为；移动端与桌面端特定语法兼容性。

## 11. 关键源码索引

- [消息行](<../../aio-hub/src/tools/llm-chat/components/message/MessageRow.vue>)、[正文适配](<../../aio-hub/src/tools/llm-chat/components/message/MessageContent.vue>)、[工具卡](<../../aio-hub/src/tools/llm-chat/components/message/ToolCallMessage.vue>)。
- [RichTextRenderer](<../../aio-hub/src/tools/rich-text-renderer/RichTextRenderer.vue>)、[V2 流处理](<../../aio-hub/src/tools/rich-text-renderer/core/StreamProcessorV2.ts>)、[AST 状态](<../../aio-hub/src/tools/rich-text-renderer/composables/useMarkdownAst.ts>)。
- [显示回收](<../../aio-hub/src/tools/rich-text-renderer/composables/useRendererDisplay.ts>)、[视图快照](<../../aio-hub/src/tools/rich-text-renderer/composables/useRendererViewState.ts>)、[块挂载](<../../aio-hub/src/tools/rich-text-renderer/composables/useRendererBlockMounting.ts>)。
- [HTML 预览](<../../aio-hub/src/tools/rich-text-renderer/components/HtmlInteractiveViewer.vue>)、[移动渲染器](<../../aio-hub/mobile/src/tools/rich-text-renderer/RichTextRenderer.vue>)。
