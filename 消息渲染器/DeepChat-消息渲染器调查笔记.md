# DeepChat 消息渲染器调查笔记

> 调查对象：`https://github.com/ThinkInAIXYZ/deepchat`（重点 `src/shared/chat.d.ts`、`src/renderer/src/components/message/`、`src/renderer/src/components/markdown/`、`src/renderer/src/components/artifacts/`）
>
> 调查更新日期：2026-08-12
>
> 代码快照：`e142b2a2eb06f903dd014326e19f87947ab92f03`（分支：`dev`）
>
> 调查方式：只读源码梳理；未修改 DeepChat 仓库
>
> 调查范围：assistant block 分发、流式 Markdown、reasoning/tool activity、Artifact 类型映射与 HTML/SVG/Mermaid 隔离、消息窗口化交接、block 类型扩展机制、性能缓存与测试覆盖、provider 搜索块渲染、权限结果徽标与 DcCopyButton 重构
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

`AssistantMessageBlock`（`src/shared/chat.d.ts:114-175`）以类型、内容、状态、时间戳为基础字段，附加 artifact descriptor、tool_call 参数/响应/图片预览、image data、reasoning time；`AssistantMessageExtra` 还记录工具来源、permission request、question、plan、subagent progress 和 `max_tool_calls`/`max_tokens` 跳过原因（`:189-231`）。

`MessageItemAssistant.vue:40-132` 的分发顺序为：activity 组（推理/工具）、MCP app、content、reasoning/artifact-thinking、provider search、tool call、提问与一般 action、音频/视频、图片、错误。activity group 内部在 `MessageBlockActivityGroup.vue:38-55` 再分派 Think 与 ToolCall，并显示推理/工具数量和耗时。

`MessageBlockThink` 将 reasoning time 转成耗时标签并持久化折叠状态；`MessageBlockToolCall`（`:317-323` 状态映射、`:537-560` 图标）根据 block status 选择 calling/response/end/error 图标，显示 server identity、参数/响应、图片预览、diff 和 MCP App result。`exec`、`process`、subagent 等工具在运行中可自动展开，属于显示规则而非数据类型变化。

另有两条分发规则（源码确认）：

- **provider search 块**：`MessageItemAssistant.vue:80-84` 对 `isProviderSearchBlock` 命中的 search 块渲染 `MessageBlockSearch.vue`（只认 search/open_page/find_in_page 三种 `actionType`）。该块显示动作链接、来源页面列表与状态图标，来源由 DeepSeek 原生 web 搜索的 `providerSearch`/`providerUrlSource` 流事件产生（见 §2）。
- **权限结果徽标**：`MessageBlockToolCall.vue:45-60` 在工具卡上显示 `granted/denied` 徽标（#2132）。工具调用权限结算后，`displayMessage.ts:242-278` 按 `tool_call.id` 把已结算的权限 action 块映射到同列表中的工具卡；映射成功时独立 action 卡被过滤（`MessageItemAssistant.vue:478-486`），只在没有对应工具卡时作为兜底保留。

## 2. Content 与 Artifact 标签解析

`useArtifacts.ts:52-90` 把 content 转为 `ProcessedPart[]`。解析器的正则在 `:92-118`：

- `<antThinking>` 支持闭合和流式未闭合形式；
- `<antArtifact type="..." identifier="..." title="...">` 支持闭合/未闭合形式；
- `<tool_call>`、`<tool_response>`、`<tool_call_end>`、`<tool_call_error>`、`<maximum_tool_calls_reached>` 按标签顺序处理，避免前缀标签抢先匹配。

解析结果区分 text/thinking/artifact/tool_call，并携带 loading、tool status、artifact type/language。流式状态下，未闭合的 tool/artifact 部分会保留到下一次 content 更新；`MessageBlockContent.vue:52-126` 依据 snapshot 同步或完成 artifact store。

**search 块的流式来源**：AI SDK stream adapter（`src/main/provider/aiSdk/streamAdapter.ts:254-291`）把 DeepSeek Responses 的 `raw`/`source` 流部件投影为 `providerSearch`/`providerUrlSource` 事件，只收 http/https 来源、上限 100 个并去重；事件经 block 化后以 search 类型落盘，交给 §1 的 `MessageBlockSearch` 渲染，是否渲染按 `extra.actionType` 区分三种动作。该链路是 provider 原生搜索（当前仅 DeepSeek `deepseek-v4-flash`）的专用路径，与 useArtifacts 的标签解析无关。

## 3. Markdown 流式渲染

`MarkdownRenderer.vue:228-241` 配置流式与静态两套批处理参数：

- 流式使用较小的 initial/render batch、短 delay 和 parse coalesce，并启用 smooth streaming/typewriter；
- 静态内容采用较大 batch，并允许 `node-virtual: auto`、最大 live nodes 与 viewport priority；
- `shouldVirtualizeNodes` 在非 streaming 状态且 `virtualizeNodes` 开启时才为 true。

组件调用 markstream-vue 的 NodeRenderer（`:1-80`），代码 renderer 使用 `monaco` 兼容名称，把代码块交给 stream-monaco；渲染完成的 artifact 点击事件通过 `artifactStore.showArtifact` 打开（`:222-235`）。链接引用节点还会按 session 搜索结果和 link context 处理（`:238-245`）。

`hiddenImageSources` 解析后变换：`MessageBlockContent.vue:20` 把 `imgcache://` 图片源列表传给 MarkdownRenderer，`:139-212` 的 `postTransformNodes` 在解析树中删除这些 image 节点（图像持久化后，已提升为独立 image 块的图不再重复出现在 Markdown 文本里）。

## 4. Artifact 类型映射

`ArtifactBlock.vue:44-75` 的类型映射为：

| artifact type | 组件 | 主要输出 |
|---|---|---|
| `application/vnd.ant.code` | `CodeArtifact` | Monaco/代码块，Mermaid 语言可进入 MermaidBlockNode |
| `text/markdown` | `MarkdownArtifact` | 再次走 Markdown 渲染 |
| `text/html` | `HTMLArtifact` | `iframe srcdoc` 预览 |
| `image/svg+xml` | `SvgArtifact` | main process 清洗后 `v-html` |
| `application/vnd.ant.mermaid` | `MermaidArtifact` | Mermaid SVG |
| `application/vnd.ant.react` | `ReactArtifact` | React template + iframe |

Artifact 预览组件共享 title、copy 和 preview 状态；artifact block 既可以在消息内容中显示，也可以通过 artifact store 打开独立预览。

## 5. Artifact 隔离

`HTMLArtifact.vue:4-11` 使用 `srcdoc` 和 `sandbox="allow-scripts allow-same-origin"`；桌面/viewport 预览还会注入 viewport meta 与基础样式（`:83-109`）。`ReactArtifact.vue:1-9` 只使用 `sandbox="allow-scripts"`，内容先经 `formatTemplate` 包装（`:30-38`）。

`SvgArtifact.vue:67-101` 不直接渲染输入，而是调用 `deviceClient.sanitizeSvgContent`，结果为空时标记错误。`MermaidArtifact.vue:74-136` 先做标签与属性清洗：移除 script、iframe、embed/object、form、link、style、meta、img 等标签，清除 on* 事件属性与 javascript/vbscript/data:text/html 三类危险协议；随后初始化 Mermaid 并设置 `securityLevel: 'strict'`。

这些边界只约束对应 artifact 路径：普通 Markdown 使用 markstream-vue 的安全 HTML policy，工具响应中的图片/diff/MCP App 又有独立的组件与状态处理。本次未把每一条外部网络请求和 CSP 配置追到应用打包层。

## 6. 消息列表、窗口化与滚动

消息列表不是一次性渲染全部历史：`MessageList`/`MessageListRow` 只接收当前窗口的 `MessageListItem`；窗口计算用估算高度 + ResizeObserver 实测 + 顶部/底部 spacer + 逻辑 anchor 维持滚动位置，消息数超阈值后用二分查找计算 viewport 附近索引范围，ChatPage 在会话切换与追加后保存/恢复测量快照。该主题与 Chat 笔记 §4「消息窗口化」为同一实现（`MessageList.vue:1-65`、`useMessageWindow.ts`、`useMessageVirtualization.ts`，均在 `src/renderer` 下），本笔记只记录交接点，不重复展开。

## 7. 扩展方式与已确认边界

新增 block 类型需要同时修改三层，未发现插件式注册表：

1. **持久化类型**：`src/shared/chat.d.ts:114-175` 的 `AssistantMessageBlock.type` 联合；
2. **IPC 契约**：`src/shared/contracts/common.ts:516-525` 的 `AssistantMessageBlockSchema` 用 zod 枚举校验 `type`，跨进程校验在此层；block `status` 枚举另含 `granted/denied`（`:527`），是权限结果的持久化形态（§1 徽标的数据来源）。持久化层的 type 取值如下：

   ```text
   content / search / reasoning_content / plan / error / tool_call / action / image
   ```
3. **展示层**：`src/renderer/src/features/chat-page/model/displayMessage.ts:125-137` 的 `DisplayAssistantMessageBlock.type` 在持久化层基础上多出 `video/audio/artifact-thinking`，由转换逻辑派生；配合 `isRenderableAssistantBlock`（:242-249，过滤 plan 与内部 tool call）与 `MessageItemAssistant.vue` 的分发链（§1）。

已确认边界：`plan` 与内部工具调用块不渲染（displayMessage.ts:242-249）；`action` 类型按动作分发到专用组件，三种取值 `tool_call_permission`、`question_request`、`rate_limit` 分别路由到审批、提问与限流提示（`chat.d.ts:163-166`）。新增类型若只存在于展示层（如 video/audio 等媒体），不需要改 IPC schema，但需要改持久化转换与分发组件。

## 8. 性能、缓存与测试

- **缓存策略**：`useArtifacts.ts` 有 last-parse memo（`:157-159`，流式重复解析同字符串直接返回缓存）；`MessageBlockContent` 对内容快照做比较后再同步 artifactStore（`MessageBlockContent.vue:95-143`）；Markdown 侧区分流式/静态两套 batch 参数与节点虚拟化（§3）。
- **渲染频率**：renderer 端接收主进程 120ms 节流发出的全块快照（`chat.stream.updated`）、DB 600ms 节流落盘，均由生成侧 `echo.ts` 控制（`src/main/agent/deepchat/runtime/echo.ts:7-8`，详细链路见生成式输出与运行时笔记 §2 与 Chat 笔记 §3），本笔记不再展开。
- **复制按钮**：工具卡的参数/响应复制用 `@dc-ui` 的 `DcCopyButton`（`MessageBlockToolCall.vue:160-202`）；整条消息复制由 `MessageItemAssistant` 的 `copyText` computed 提供，供 `MessageToolbar` 使用（`MessageItemAssistant.vue:428-450`）。
- **测试覆盖（静态确认，未运行）**：`test/renderer/components/message/` 下 12 个组件测试（`MessageItemAssistant.test.ts`、`MessageBlockToolCall.test.ts`、`MessageBlockContent.test.ts`、`MessageBlockThink.test.ts`、`MessageBlockActivityGroup.test.ts`、`MessageBlockMedia.test.ts` 等）；Artifact 侧有 `HTMLArtifact/MarkdownArtifact/MermaidArtifact/ReactArtifact/SvgArtifact/MarkdownRenderer.test.ts` 与 `useArtifacts/useArtifactContext/useArtifactExport/useArtifactViewMode.test.ts`、`stores/sidepanelAndArtifact.test.ts`。未发现长会话/大数据量的虚拟化性能基准测试。
- 视觉表现、键盘可用性与长会话滚动性能均未运行验证（见 §9）。

## 9. 边界与未验证事项

- HTML artifact 允许脚本执行；sandbox 是否与 Electron webPreferences、网络权限和 CSP 组合生效，未通过浏览器或桌面运行验证。
- SVG sanitizer 在 main process，renderer 只消费结果；未执行恶意 SVG/Mermaid corpus 验证清洗覆盖率。
- 流式未闭合标签和节点虚拟化依赖 markstream-vue/stream-monaco 版本行为，本次未运行极长消息、快速切换 session 或移动端布局。
- assistant block 的 metadata 可表示 permission、question、plan 和 tool result，但本次未逐个追踪这些交互组件的可访问性与错误降级。
- 新增 block 类型的三层修改点（§7）为静态确认；未实际运行一次"新增类型"的开发流程验证遗漏面。
- 未运行项目测试、构建或 UI 截图验证；记录来自静态源码。

## 10. 关键源码索引

- assistant block 类型与 metadata：`src/shared/chat.d.ts:114-231`
- assistant 分发与 activity group：`src/renderer/src/components/message/MessageItemAssistant.vue:40-132`、`src/renderer/src/components/message/MessageBlockActivityGroup.vue:38-55`
- 权限结果徽标：`src/renderer/src/features/chat-page/model/displayMessage.ts:242-278`、`MessageBlockToolCall.vue:45-60`
- search 块：`src/renderer/src/components/message/MessageBlockSearch.vue`、`messageActivityGroups.ts:52-57`
- tool call 展示：`src/renderer/src/components/message/MessageBlockToolCall.vue:317-323`、`:537-560`
- thinking/artifact/tool 标签解析：`src/renderer/src/composables/useArtifacts.ts:52-150`、`:220-490`
- content block 与 artifact store：`src/renderer/src/components/message/MessageBlockContent.vue:1-126`
- Markstream 流式/虚拟化参数：`src/renderer/src/components/markdown/MarkdownRenderer.vue:228-241`
- artifact 类型映射：`src/renderer/src/components/artifacts/ArtifactBlock.vue:44-75`
- HTML/React iframe：`src/renderer/src/components/artifacts/HTMLArtifact.vue:4-109`、`src/renderer/src/components/artifacts/ReactArtifact.vue:1-38`
- SVG sanitizer 调用：`src/renderer/src/components/artifacts/SvgArtifact.vue:63-107`
- Mermaid 清洗和 strict 模式：`src/renderer/src/components/artifacts/MermaidArtifact.vue:74-136`
- block 类型三层定义：`src/shared/chat.d.ts:114-175`、`src/shared/contracts/common.ts:516-525`、`src/renderer/src/features/chat-page/model/displayMessage.ts:125-193`
- 消息窗口化与滚动（交接 Chat 笔记 §4）：`src/renderer/src/components/chat/MessageList.vue:1-65`、`useMessageWindow.ts`、`useMessageVirtualization.ts`
- 渲染相关测试：`test/renderer/components/message/`、`test/renderer/components/HTMLArtifact.test.ts` 等

