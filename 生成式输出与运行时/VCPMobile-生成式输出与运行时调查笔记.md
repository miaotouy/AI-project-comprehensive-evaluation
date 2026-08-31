# VCPMobile 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/MRiecy/VCPMobile`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`cecdbe432feda57821938bba7625a272113d21c1`（分支：`main`）
>
> 调查方式：只读静态源码核对，覆盖流式内容块解析、消息持久化和 HTML 预览组件；未运行 Tauri WebView 或测试脚本
>
> 调查范围：模型输出形成 `html-preview` 专用对象并在 iframe 中运行的链路；普通 Markdown、思考块、工具卡和日记块的视觉细节留给消息渲染器/会话类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPMobile 的可执行生成式输出是消息内的 HTML 预览块，可定位为 G3“可执行 Artifact”，但不具备 G4/G5 的独立工作区或持续维护能力。模型响应中的 HTML 围栏或完整 HTML 文档会被解析成 `html-preview` 内容块，用户可以切换代码/预览、复制源码、刷新 iframe、全屏查看；预览在 sandboxed iframe 中运行脚本和表单。

该对象的事实源仍是聊天消息原文。解析出的 blocks 是与消息内容哈希关联的渲染缓存，不是有独立 ID、可编辑源文件、版本分支或模型可查询列表的 Artifact。日记、工具结果等也有专用块类型，但在本次范围内未确认其构成独立执行环境。

## 系统边界与主链路

```text
流式/最终模型文本
  -> 内容解析器识别 ```html 或 <html>/<!doctype html>
  -> ContentBlock::HtmlPreview（源码 + 高亮缓存 + hash）
  -> 消息 render_content 缓存，随聊天消息恢复
  -> HtmlPreviewBlock 代码视图或 iframe srcdoc
  -> 用户复制、刷新、全屏预览；未回流模型
```

内容解析器将 HTML 围栏与完整文档分别转为 `HtmlPreview`；容器级普通 HTML 则仍按 Markdown raw HTML 处理。`src-tauri/src/vcp_modules/chat/content_parser.rs:356-373,497-800`。消息服务在缓存命中时读取 blocks，未命中时从原文重新编译并通过内容哈希保护的缓存写回 SQLite。`src-tauri/src/vcp_modules/chat/message_service.rs:484-539,908-947`。

## 1. 输出协议、对象模型与持久化

前端 `ContentBlock` 为 `html-preview` 定义 `content`、`highlighted_content` 和 `hash` 字段；同一消息以 `ChatMessage.id` 为稳定归属。Rust 端 `ContentBlock::html_preview` 会生成 HTML 高亮内容并参与块哈希计算。`src/core/types/chat.ts:47-85,186-212`，`src-tauri/src/vcp_modules/chat/content_parser.rs:10-116,225-278`。

持久化保存的是消息原文与序列化后的渲染缓存。缓存会因原文内容哈希或渲染器 schema 不匹配而失效并重新编译；没有专用 artifact 表、独立生命周期状态、版本号、分享链接或导出命令。`src-tauri/src/vcp_modules/chat/message_service.rs:496-537`。

## 2. 表现、执行环境与交互

预览组件默认展示代码；用户切换预览后会把清洗后的 HTML 填入 iframe `srcdoc`。页面提供复制、刷新和全屏预览，主题变化会重新生成注入样式；图片点击会通过 `postMessage` 通知父页面。`src/features/chat/blocks/HtmlPreviewBlock.vue:34-163,239-300`。

iframe 使用无 `allow-same-origin` 的 sandbox，同时允许脚本、模态、表单；全屏版本额外允许弹出窗口。DOMPurify 先处理 HTML，但组件仍显式将 `script`、`iframe`、`canvas` 等加入允许标签列表。因此可确认这是浏览器脚本运行表面，而不是只读高亮；本次未在真实 WebView 中验证 DOMPurify 对不同 HTML、网络请求和嵌套 iframe 的最终效果。`src/features/chat/blocks/HtmlPreviewBlock.vue:58-125,226-233,289-296`。

## 3. 更新、回流与资源边界

流式阶段的 Aurora 更新可携带稳定 blocks 与尾部 block，最终消息统一持久化渲染缓存；这使 HTML 块随消息刷新和重开恢复，但更新粒度仍是消息内容/块重编译，而非对独立 Artifact 的文件 diff。`src/core/types/chat.ts:136-154,214-241`。

未找到用户直接编辑 HTML、保存为单独文件、将 iframe 状态恢复、模型读取已有 HTML 源码、按对象 ID 修改、能力桥调用 Tauri API，或不可见 iframe 的专门资源治理。组件卸载时仅清理刷新计时器并注销全屏 modal。`src/features/chat/blocks/HtmlPreviewBlock.vue:132-163`。

## 4. 已确认边界与未验证事项

- 能力谱系为 G3：可执行 HTML 预览；不宜据此称为可编辑工作区或长期活对象。
- 日记/工具块的专用消息表示不自动等价于 Artifact 运行时；本笔记没有将它们计为独立输出对象。
- 未运行 Android WebView，未验证半截流式 HTML 的视觉收口、脚本执行、跨域资源、弹窗、内存释放与历史恢复的真实表现。

## 关键源码索引

- `src-tauri/src/vcp_modules/chat/content_parser.rs`：HTML 触发协议与内容块生成。
- `src-tauri/src/vcp_modules/chat/message_service.rs`：消息原文与渲染缓存的持久化/重编译。
- `src/core/types/chat.ts`：跨 Rust/Vue 的内容块和流式更新契约。
- `src/features/chat/blocks/HtmlPreviewBlock.vue`：代码、预览、全屏和 iframe sandbox 运行表面。
