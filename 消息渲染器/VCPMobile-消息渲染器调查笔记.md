# VCPMobile 消息渲染器调查笔记

> 调查对象：`VCPMobile`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`9da3baac9fb9d610bc31be40a6dc8d6c66774890`（分支：`main`）
>
> 调查方式：静态阅读 Rust 内容预渲染、SQLite 渲染缓存、Vue 消息组件、AST 执行器与附件组件
>
> 调查范围：聊天现场的消息、富内容、流式更新与内容承载；不覆盖请求语义和导出渲染
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPMobile 在 Rust 侧预渲染消息内容：消息写入/读取阶段把内容编译为结构化 blocks 和 Markdown AST，并压缩保存到 `render_cache`；Vue 的 `MessageRenderer` 将历史 AST 一次性转成 HTML，并为流式尾部按帧应用稀疏 AST mutation。较新的实现把这两种重复的流式形态（思考尾部、代码/HTML 尾部）下沉到一个 DOM 执行器微内核，由 `applyFrame` 与 thought/code-patch executor 承担，`MessageRenderer` 只负责装配与失败回退。该设计把常规历史读取与流式 UI 的渲染成本分开。

## 总体渲染链路

历史查询优先读取 render cache，缓存缺失时解压正文、解析 content blocks 和 Markdown AST，并异步回写缓存；用户编辑、终结流和强制重渲染会更新它，见 `src-tauri/src/vcp_modules/chat/message_service.rs:29-135,859-904,1410-1545`。前端按消息 ID 取活动流对象或持久化消息，然后 `MessageRenderer` 按 message bubbles、blocks、尾部状态和附件分派组件，尾部帧执行入口见 `src/features/chat/MessageRenderer.vue:100-140,1089-1160,1207-1360`。

## 1. 消息与内容块数据模型

消息携带预计算的 shell、正文和可选 blocks。内容块覆盖 Markdown、思考、工具、日记、工具调用摘要、样式和 HTML 等特种内容；Markdown block 内部保存节点数组而非原始 DOM，见 `src/core/types/chat.ts:102-410`。Shell 在 Rust 端按用户或 Agent 预计算，避免列表渲染时重复查询身份。

附件另以 MIME/文件名分类，并由 registry 映射到图片、视频、音频、文档、代码、文本或其他组件；本地可用性决定是否允许打开、预览或保存，见 `src/features/chat/attachment/AttachmentRenderer.vue:30-40` 与 `AttachmentViewer.vue:161-177`。

## 2. 流式数据到 UI 的更新链

收到 thinking 时创建助手气泡并标记活动流；aurora 事件包含已稳定 blocks、尾部文本、尾部块和可选 AST frame。stream store 合并多个事件到每消息待提交对象（`mergeTailFrame` 与尾部游标），再用 requestAnimationFrame 一次写入 reactive 消息，避免每个网络块触发 DOM 刷新，见 `src/core/stores/chatStreamStore.ts:140-520`。

结束或错误事件先强制 flush 待处理帧。若终态自带 blocks 则直接使用，否则请求 Rust 重新编译；随后清空 tail、移除活动状态。前端可显示状态，但最终正文和缓存写入由 Rust 事务负责，见 `src/core/stores/chatStreamStore.ts:512-600`。

## 3. 列表、消息壳与性能

ChatView 分页加载而不使用传统虚拟列表，消息渲染节点自身还使用 CSS content-visibility 延后屏外布局。滚动状态机以顶部消息 ID 做锚点，以减少 prepend 历史后的跳动；这些策略只从静态代码确认，未实测长会话表现，见 `src/features/chat/ChatView.vue:41-198`。

消息壳按预计算 shell 分出用户与助手视觉身份。Thinking indicator、streaming tag、时间和长按菜单被放在消息项周围；助手内容可由多个 bubble 和特种块组成，见 `src/features/chat/MessageRenderer.vue:1207-1360`。

## 4. Markdown、富块与内容交互

AST renderer 将段落、标题、代码、表格、链接、图片等节点转为 HTML，并以 message ID/hash 作 LRU 缓存键（容量上限 500）。代码块可用 Rust 高亮结果；KaTeX 与 Mermaid 在 Vue 端按需加载，Mermaid 有 30 项缓存和全屏查看，见 `src/core/utils/astRenderer.ts:169-260` 与 `src/features/chat/MessageRenderer.vue:489-720`。

思考、工具和日记使用专门块。工具结果可折叠、全屏和复制字段；消息菜单则提供整条内容复制、编辑、重渲染和重新生成。它们的请求/数据变更语义分别交给相邻专题，见 `src/features/chat/blocks/ToolBlock.vue:78-260` 和 `src/features/chat/MessageRenderer.vue:860-940`。

## 5. HTML 与内容承载边界

普通 AST 转 HTML 前会移除脚本等主动文档标签、可执行 URL 和能直达宿主能力的事件处理器，并给 iframe 添加/收紧 sandbox。该过滤器是项目特定的富内容 guard，而非通用不可信 HTML 安全结论，见 `src/core/utils/astRenderer.ts:29-167`。

独立 HTML block 走代码/预览双模式，预览置于 sandboxed iframe；该 iframe 只保留 `allow-scripts` 且不经 DOMPurify 清洗，源码注释以 opaque origin 与 sandbox 作为唯一边界，见 `src/features/chat/blocks/HtmlPreviewBlock.vue:73-122,224-296`。因此普通消息 AST 与独立 HTML 预览有不同的承载契约。

## 未验证事项

未运行验证 DOM 过滤对复杂 HTML 的效果、iframe 与 WebView 的实际隔离、KaTeX/Mermaid 的故障回退、AST diff 在长流和前后台切换中的一致性，以及屏外渲染的内存收益。

## 关键源码索引

- `src-tauri/src/vcp_modules/chat/message_service.rs:29-135,859-904,1410-1545`
- `src/core/stores/chatStreamStore.ts:140-600`
- `src/features/chat/MessageRenderer.vue:489-720,860-940,1207-1360`
- `src/core/utils/astRenderer.ts:29-167,169-260`
- `src/features/chat/blocks/HtmlPreviewBlock.vue:73-122,224-296`
