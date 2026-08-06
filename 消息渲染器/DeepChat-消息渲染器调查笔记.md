# DeepChat 消息渲染器调查笔记

> 调查对象：`E:\works\git\deepchat`（重点 `src/shared/chat.d.ts`、`src/renderer/src/components/message/`、`src/renderer/src/components/markdown/`、`src/renderer/src/components/artifacts/`）
>
> 调查更新日期：2026-08-06
>
> 代码快照：`dc4177c2ac80905ebac985554a9f957aaca31ab8`（分支：`dev`）
>
> 调查方式：只读源码梳理；未修改 DeepChat 仓库
>
> 调查范围：assistant block 分发、流式 Markdown、reasoning/tool activity、Artifact 类型映射与 HTML/SVG/Mermaid 隔离
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 的 renderer 以结构化 assistant blocks 为主，Markdown 与 Artifact 是 block 内的子渲染路径：

1. `AssistantMessageBlock` 明确定义 content、search、reasoning_content、plan、error、tool_call、action、image、audio 和 artifact-thinking 等类型，状态与工具/权限/plan metadata 分开保存。
2. `MessageItemAssistant` 按 activity group、content、reasoning、tool call、action、媒体和 error 分发；reasoning/tool 可折叠，tool call 可显示参数、响应、图片、diff 和 MCP App view。
3. `MessageBlockContent` 通过 `useArtifacts` 解析 `<antThinking>`、`<antArtifact>` 和 legacy `<tool_call>` 标签，兼容流式未闭合标签，并把 artifact 交给 ArtifactBlock。
4. `MarkdownRenderer` 使用 markstream-vue；代码块由 stream-monaco/Monaco surface 渲染，流式与静态内容采用不同的 render batch、viewport priority 和节点虚拟化参数。静态长文可虚拟化，流式内容保持平滑输出。
5. Artifact 类型映射到 Code、Markdown、HTML、SVG、Mermaid、React。HTML/React 使用 iframe sandbox；SVG 先交给 main process sanitizer；Mermaid 在渲染前移除危险标签、事件属性和协议，并初始化为 `securityLevel: strict`。

## 调用链

```text
deepchat_assistant_blocks
  -> DisplayMessage / DisplayAssistantMessageBlock
  -> MessageItemAssistant
     -> MessageBlockActivityGroup
        -> MessageBlockThink / MessageBlockToolCall
     -> MessageBlockContent
        -> useBlockContent / useArtifacts
           -> MarkdownRenderer 或 ArtifactBlock
     -> image/audio/action/error 专用组件
```

## 1. Block 数据模型与分发

`AssistantMessageBlock`（`src/shared/chat.d.ts:114-175`）以 `type`、`content`、`status`、`timestamp` 为基础，附加 artifact descriptor、tool_call 参数/响应/图片预览、image data、reasoning time。`AssistantMessageExtra` 还记录工具来源、permission request、question、plan、subagent progress 和 `max_tool_calls`/`max_tokens` 跳过原因（`:189-231`）。

`MessageItemAssistant.vue:42-119` 的分发顺序为：activity-group、content、reasoning/artifact-thinking、tool_call、question action、一般 action、image/audio、error。activity group 内部在 `MessageBlockActivityGroup.vue:38-49` 再分派 Think 与 ToolCall，并显示推理/工具数量和耗时。

`MessageBlockThink` 将 reasoning time 转成耗时标签并持久化折叠状态；`MessageBlockToolCall`（`:300-378`、`:496-617`）根据 block status 选择 calling/response/end/error 图标，显示 server identity、参数/响应、图片预览、diff 和 MCP App result。`exec`、`process`、subagent 等工具在运行中可自动展开，属于显示规则而非数据类型变化。

## 2. Content 与 Artifact 标签解析

`useArtifacts.ts:52-90` 把 content 转为 `ProcessedPart[]`。解析器的正则在 `:92-118`：

- `<antThinking>` 支持闭合和流式未闭合形式；
- `<antArtifact type="..." identifier="..." title="...">` 支持闭合/未闭合形式；
- `<tool_call>`、`<tool_response>`、`<tool_call_end>`、`<tool_call_error>`、`<maximum_tool_calls_reached>` 按标签顺序处理，避免前缀标签抢先匹配。

解析结果区分 text/thinking/artifact/tool_call，并携带 loading、tool status、artifact type/language。流式状态下，未闭合的 tool/artifact 部分会保留到下一次 content 更新；`MessageBlockContent.vue:52-126` 依据 snapshot 同步或完成 artifact store。

## 3. Markdown 流式渲染

`MarkdownRenderer.vue:125-190` 配置流式与静态两套批处理参数：

- 流式使用较小的 initial/render batch、短 delay 和 parse coalesce，并启用 smooth streaming/typewriter；
- 静态内容采用较大 batch，并允许 `node-virtual: auto`、最大 live nodes 与 viewport priority；
- `shouldVirtualizeNodes` 在非 streaming 状态且 `virtualizeNodes` 开启时才为 true。

组件调用 markstream-vue 的 NodeRenderer（`:1-80`），代码 renderer 使用 `monaco` 兼容名称，把代码块交给 stream-monaco；渲染完成的 artifact 点击事件通过 `artifactStore.showArtifact` 打开（`:222-235`）。链接引用节点还会按 session 搜索结果和 link context 处理（`:238-245`）。

## 4. Artifact 类型映射

`ArtifactBlock.vue:24-65` 的类型映射为：

| artifact type | 组件 | 主要输出 |
|---|---|---|
| `application/vnd.ant.code` | `CodeArtifact` | Monaco/代码块，Mermaid 语言可进入 MermaidBlockNode |
| `text/markdown` | `MarkdownArtifact` | 再次走 Markdown 渲染 |
| `text/html` | `HTMLArtifact` | `iframe srcdoc` 预览 |
| `image/svg+xml` | `SvgArtifact` | main process 清洗后 `v-html` |
| `application/vnd.ant.mermaid` | `MermaidArtifact` | Mermaid SVG |
| `application/vnd.ant.react` | `ReactArtifact` | React template + iframe |

Artifact 预览组件共享 title、copy 和 preview 状态；artifact block 既可以在消息内容中显示，也可以通过 artifact store 打开独立预览。

## 5. 安全与隔离边界

`HTMLArtifact.vue:4-11` 使用 `srcdoc` 和 `sandbox="allow-scripts allow-same-origin"`；桌面/viewport 预览还会注入 viewport meta 与基础样式（`:83-109`）。`ReactArtifact.vue:1-9` 只使用 `sandbox="allow-scripts"`，内容先经 `formatTemplate` 包装（`:30-38`）。

`SvgArtifact.vue:67-101` 不直接渲染输入，而是调用 `deviceClient.sanitizeSvgContent`，结果为空时标记错误。`MermaidArtifact.vue:74-123` 移除 script、iframe、object/embed、form、link、style、meta、img，清除 on* 属性和 javascript/vbscript/data:text/html 协议；初始化 Mermaid 时设置 `securityLevel: 'strict'`（`:125-136`）。

这些边界只约束对应 artifact 路径：普通 Markdown 使用 markstream-vue 的安全 HTML policy，工具响应中的图片/diff/MCP App 又有独立的组件与状态处理。本次未把每一条外部网络请求和 CSP 配置追到应用打包层。

## 6. 边界与未验证事项

- HTML artifact 允许脚本执行；sandbox 是否与 Electron webPreferences、网络权限和 CSP 组合生效，未通过浏览器或桌面运行验证。
- SVG sanitizer 在 main process，renderer 只消费结果；未执行恶意 SVG/Mermaid corpus 验证清洗覆盖率。
- 流式未闭合标签和节点虚拟化依赖 markstream-vue/stream-monaco 版本行为，本次未运行极长消息、快速切换 session 或移动端布局。
- assistant block 的 metadata 可表示 permission、question、plan 和 tool result，但本次未逐个追踪这些交互组件的可访问性与错误降级。
- 未运行项目测试、构建或 UI 截图验证；记录来自静态源码。

## 7. 关键源码索引

- assistant block 类型与 metadata：`src/shared/chat.d.ts:114-231`
- assistant 分发与 activity group：`src/renderer/src/components/message/MessageItemAssistant.vue:42-119`、`src/renderer/src/components/message/MessageBlockActivityGroup.vue:38-49`
- tool call 展示：`src/renderer/src/components/message/MessageBlockToolCall.vue:300-378`、`:496-617`
- thinking/artifact/tool 标签解析：`src/renderer/src/composables/useArtifacts.ts:52-150`、`:220-490`
- content block 与 artifact store：`src/renderer/src/components/message/MessageBlockContent.vue:1-126`
- Markstream 流式/虚拟化参数：`src/renderer/src/components/markdown/MarkdownRenderer.vue:125-190`
- artifact 类型映射：`src/renderer/src/components/artifacts/ArtifactBlock.vue:24-65`
- HTML/React iframe：`src/renderer/src/components/artifacts/HTMLArtifact.vue:4-109`、`src/renderer/src/components/artifacts/ReactArtifact.vue:1-38`
- SVG sanitizer 调用：`src/renderer/src/components/artifacts/SvgArtifact.vue:63-107`
- Mermaid 清洗和 strict 模式：`src/renderer/src/components/artifacts/MermaidArtifact.vue:74-136`

