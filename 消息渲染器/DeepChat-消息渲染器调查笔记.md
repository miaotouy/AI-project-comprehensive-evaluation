# DeepChat 消息渲染器调查笔记

> 调查对象：`https://github.com/ThinkInAIXYZ/deepchat`（重点 `src/shared/chat.d.ts`、`src/renderer/src/components/message/`、`src/renderer/src/components/markdown/`）
>
> 调查更新日期：2026-11-04
>
> 代码快照：`3db91f876ad903b17215da94cd1a4a6398823dad`（分支：`dev`）
>
> 调查方式：只读源码梳理；未修改 DeepChat 仓库
>
> 调查范围：assistant block 分发、流式 Markdown、reasoning/tool activity、历史 Artifact 标记的兼容渲染、消息窗口化交接、block 类型扩展机制、性能缓存与测试覆盖、provider 搜索块渲染、权限结果徽标与复制按钮
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepChat 的 renderer 以结构化 assistant blocks 为主，Markdown 与历史 Artifact 标记是 block 内的子渲染路径：

1. `AssistantMessageBlock` 明确定义 content、search、reasoning_content、plan、error、tool_call、action、image、audio 和 artifact-thinking 等类型，状态与工具/权限 metadata 分开保存；其中 plan 与 artifact-thinking 只作为历史消息兼容形态保留。
2. `MessageItemAssistant` 按 activity group、content、reasoning、tool call、action、媒体和 error 分发；reasoning/tool 可折叠，tool call 可显示参数、响应、图片、diff 和 MCP App view。
3. `MessageBlockContent` 通过 `useArtifacts` 解析 `<antThinking>`、`<antArtifact>` 和 legacy `<tool_call>` 标签，兼容流式未闭合标签；解析出的 artifact 交给 `LegacyArtifactSource` 兼容视图，只显示标题与可复制原文。
4. `MarkdownRenderer` 使用 markstream-vue；代码块由 stream-monaco/Monaco surface 渲染，流式与静态内容采用不同的 render batch、viewport priority 和节点虚拟化参数。静态长文可虚拟化，流式内容保持平滑输出。
5. 历史 Artifact 的六种 type 都只按原文展示：内建 HTML/React iframe、SVG sanitizer 与 Mermaid 清洗渲染链已随 Artifact 退役移除，普通 Markdown 改用 markstream-vue 的 HTML 安全策略。
6. Markstream 渲染路径使用独立的流式 diff 工作池；同时，压缩边界由 `MessageListRow` 的专用分隔行表达，不进入 assistant block 分发（`src/renderer/src/lib/markstreamLanguage.ts`、`src/renderer/src/components/chat/MessageListRow.vue`）。
7. 连续的 reasoning 与 tool-call blocks 在结算后可折叠成 activity group；仍在流式的行保持逐块显示。分组只改变展示投影，不改变持久化 block 顺序。

## 调用链

```text
deepchat_assistant_blocks
  -> DisplayMessage / DisplayAssistantMessageBlock
  -> MessageItemAssistant
     -> MessageBlockActivityGroup
        -> MessageBlockThink / MessageBlockToolCall
     -> MessageBlockContent
        -> useBlockContent / useArtifacts
           -> MarkdownRenderer 或 LegacyArtifactSource
     -> image/audio/action/error 专用组件
```

## 1. Block 数据模型与分发

`AssistantMessageBlock`（`src/shared/chat.d.ts:102-163`）以类型、内容、状态、时间戳为基础字段，附加 artifact descriptor、tool_call 参数/响应/图片预览、image data、reasoning time；`AssistantMessageExtra` 还记录工具来源、permission request、question、subagent progress 和 `max_tool_calls`/`max_tokens` 跳过原因（`:177` 起）。

`MessageItemAssistant.vue:34-141` 的分发顺序为：activity 组（推理/工具）、MCP app、content、reasoning/artifact-thinking、provider search、tool call、提问与一般 action、音频/视频、图片、错误。activity group 内部在 `MessageBlockActivityGroup.vue` 再分派 Think 与 ToolCall，并显示推理/工具数量和耗时。

`buildAssistantRenderItems`（`src/renderer/src/components/message/messageActivityGroups.ts:138`）会把相邻的 reasoning/tool-call 块缓冲成活动组；只有一个块时保持原组件，多个块才生成稳定 group key。当前正在流式的消息行保持未分组，以便实时显示活动变化；折叠后仍保留子项的展开状态和焦点回迁（`MessageItemAssistant.vue:486-548`）。

`MessageBlockThink` 将 reasoning time 转成耗时标签并持久化折叠状态；`MessageBlockToolCall`（`:24-70` 状态环与徽标、`:360-620` 展开与图标规则）根据 block status 选择 running/reviewing/error 图标，显示 server identity、参数/响应、图片预览、diff 和 MCP App result。`exec`、`process`、subagent 等工具在运行中可自动展开，属于显示规则而非数据类型变化。

另有两条分发规则（源码确认）：

- **provider search 块**：`MessageItemAssistant.vue:88` 对 `isProviderSearchBlock` 命中的 search 块渲染 `MessageBlockSearch.vue`（只认 search/open_page/find_in_page 三种 `actionType`）。该块显示动作链接、来源页面列表与状态图标，来源由 DeepSeek 原生 web 搜索的 `providerSearch`/`providerUrlSource` 流事件产生（见 §2）。
- **权限结果徽标**：`MessageBlockToolCall.vue:63-70` 在工具卡上显示 `granted/denied` 徽标（#2132）。工具调用权限结算后，`displayMessage.ts:262` 起的映射按 `tool_call.id` 把已结算的权限 action 块对应到同列表中的工具卡；映射成功时独立 action 卡被过滤（`MessageItemAssistant.vue:527-543`），只在没有对应工具卡时作为兜底保留。

## 2. Content 与历史标签解析

`useArtifacts.ts:37` 的 `useBlockContent` 把 content 转为 `ProcessedPart[]`，解析入口在 `:58` 起的正则集合与 `:284` 的 `generatePart`：

- `<antThinking>` 支持闭合和流式未闭合形式；
- `<antArtifact type="..." identifier="..." title="...">` 支持闭合/未闭合形式；
- `<tool_call>`、`<tool_response>`、`<tool_call_end>`、`<tool_call_error>`、`<maximum_tool_calls_reached>` 按标签顺序处理，避免前缀标签抢先匹配。

解析结果区分 text/thinking/artifact/tool_call，并携带 loading、tool status、artifact type/language。流式状态下，未闭合的 tool/artifact 部分会保留到下一次 content 更新；`MessageBlockContent.vue:66-70` 消费 `useBlockContent` 的输出，artifact part 交给 `LegacyArtifactSource`（`:26-33`），没有 artifact store 同步。

**search 块的流式来源**：AI SDK stream adapter（`src/main/provider/aiSdk/streamAdapter.ts:111-200`）把 DeepSeek Responses 的 `raw`/`source` 流部件投影为 `providerSearch`/`providerUrlSource` 事件，只收 http/https 来源、上限 100 个并去重；事件经 block 化后以 search 类型落盘，交给 §1 的 `MessageBlockSearch` 渲染，是否渲染按 `extra.actionType` 区分三种动作。该链路是 provider 原生搜索（当前仅 DeepSeek `deepseek-v4-flash`）的专用路径，与历史标签解析无关。

## 3. Markdown 流式渲染

`MarkdownRenderer.vue:217-257` 配置流式与静态两套批处理参数：

- 流式使用较小的 initial/render batch、短 delay 和 parse coalesce，并启用 smooth streaming/typewriter；
- 静态内容采用较大 batch，并允许 `node-virtual: auto`、最大 live nodes 与 viewport priority；
- `shouldVirtualizeNodes` 在非 streaming 状态且 `virtualizeNodes` 开启时才为 true（`:257`）。

组件调用 markstream-vue 的 NodeRenderer（`:6-30`），代码 renderer 使用 `monaco` 兼容名称，把代码块交给 stream-monaco。链接引用节点还会按 session 引用与 link context 处理（`:181-190`）。

`hiddenImageSources` 解析后变换：`MessageBlockContent.vue:23` 把 `imgcache://` 图片源列表传给 MarkdownRenderer，`:181-190` 的 `postTransformNodes` 在解析树中删除这些 image 节点（图像持久化后，已提升为独立 image 块的图不再重复出现在 Markdown 文本里）。

## 4. 历史 Artifact 兼容渲染

`MessageBlockContent.vue:26-33` 把 artifact part 交给 `LegacyArtifactSource.vue`，后者只有一个布局：标题栏（`block.artifact.title`）+ 复制按钮（`DcCopyButton` 复制整段原文）+ 只读 `<pre>` 原文。六种历史 type 不再分派到不同渲染组件：

| artifact type | 现在的输出 |
|---|---|
| `application/vnd.ant.code` | 纯文本原文 |
| `text/markdown` | 纯文本原文 |
| `text/html` | 纯文本原文，不进入 iframe |
| `image/svg+xml` | 纯文本原文，不做 sanitizer 渲染 |
| `application/vnd.ant.mermaid` | 纯文本原文，不初始化 Mermaid |
| `application/vnd.ant.react` | 纯文本原文，不执行 |

`.vue` 组件层面的 Artifact 预览、artifact store 与独立预览表面都已移除；`artifact-thinking` 块仍按 reasoning 样式折叠显示，导出器也保留对应分支（`conversationExporter.ts:244` 等）。

## 5. 剩余能力的隔离边界

Artifact 运行时退役后，本类目剩下的执行面是 MCP App 与工作区文件预览，二者都不经过 Markdown 渲染器：

- **MCP App**：双层 iframe + 动态 CSP，由 `src/main/mcp/apps/sandboxProtocol.ts` 生成代理页，`McpAppView.vue` 承载（详见生成式输出与运行时笔记 §7.1）。
- **工作区文件预览**：HTML/SVG/PDF 经 `workspace-preview://` 协议进入 iframe，`WorkspacePreviewPane.vue:47`、`:157` 使用 `allow-scripts allow-same-origin`；SVG 另有 `WorkspaceSvgPreview.vue`。
- **普通 Markdown**：沿用 markstream-vue 的安全 HTML policy；工具响应中的图片/diff 有独立组件与状态处理。
- 本次未把每一条外部网络请求和 CSP 配置追到应用打包层；`deepcdn://` 协议仍注册但本次未找到使用方（生成式输出与运行时笔记 §4）。

## 6. 消息列表、窗口化与滚动

消息列表不是一次性渲染全部历史：`MessageList`/`MessageListRow` 只接收当前窗口的 `MessageListItem`；窗口计算用估算高度 + ResizeObserver 实测 + 顶部/底部 spacer + 逻辑 anchor 维持滚动位置，消息数超阈值后用二分查找计算 viewport 附近索引范围，ChatPage 在会话切换与追加后保存/恢复测量快照。该主题与 Chat 笔记 §4「消息窗口化」为同一实现（`MessageList.vue:1-65`、`useMessageWindow.ts`、`useMessageVirtualization.ts`，均在 `src/renderer` 下），本笔记只记录交接点，不重复展开。

## 7. 扩展方式与已确认边界

新增 block 类型需要同时修改三层，未发现插件式注册表：

1. **持久化类型**：`src/shared/chat.d.ts:102-163` 的 `AssistantMessageBlock.type` 联合；
2. **IPC 契约**：`src/shared/contracts/common.ts:566` 的 `AssistantMessageBlockSchema` 用 zod 枚举校验 `type`，跨进程校验在此层；block `status` 枚举另含 `granted/denied`，是权限结果的持久化形态（§1 徽标的数据来源）。持久化层的 type 取值如下：

   ```text
   content / search / reasoning_content / plan / error / tool_call / action / image / audio / artifact-thinking
   ```
3. **展示层**：`src/renderer/src/features/chat-page/model/displayMessage.ts:147-159` 的 `DisplayAssistantMessageBlock.type` 比持久化层多出 `video`，由转换逻辑派生；配合 `isRenderableAssistantBlock`（`:294`，过滤 plan、空内容与内部 tool call）与 `MessageItemAssistant.vue` 的分发链（§1）。

已确认边界：`plan` 与内部工具调用块不渲染（`displayMessage.ts:294`）；`action` 类型按动作分发到专用组件，三种取值 `tool_call_permission`、`question_request`、`rate_limit` 分别路由到审批、提问与限流提示（`chat.d.ts:150-155`）。新增类型若只存在于展示层（如 video/audio 等媒体），不需要改 IPC schema，但需要改持久化转换与分发组件。`plan` 与 `artifact-thinking` 属历史形态：前者继续被 `isRenderableAssistantBlock` 过滤，后者仍按 reasoning 样式折叠显示。

## 8. 性能、缓存与测试

- **缓存策略**：`useArtifacts.ts` 有 last-parse memo（`:118` 起，流式重复解析同字符串直接返回缓存）；`MessageBlockContent` 对内容快照做比较后再更新解析结果（`MessageBlockContent.vue:66-90`）；Markdown 侧区分流式/静态两套 batch 参数与节点虚拟化（§3）。
- **历史 Artifact 解析缓存**：提取结果按 block 引用记忆，消息行重渲染时复用既有解析对象；该优化依赖不可变 block 引用契约，入口见 `src/renderer/src/composables/useArtifacts.ts`。
- **非视觉模式**：应用启用 accessibility support 时，ChatPage 关闭消息窗口化，消息区成为可聚焦 region；折叠组和工具卡提供 `aria-expanded/aria-controls`。这是静态接线事实，屏幕阅读器实际播报顺序仍未运行验证。
- **渲染频率**：renderer 端接收主进程 120ms 节流发出的全块快照（`chat.stream.updated`）、DB 600ms 节流落盘，均由生成侧 `echo.ts` 控制（`src/main/agent/deepchat/runtime/echo.ts:6-7`，详细链路见生成式输出与运行时笔记 §2 与 Chat 笔记 §3），本笔记不再展开。
- **复制按钮**：工具卡的参数/响应复制用 `@dc-ui` 的 `DcCopyButton`（`MessageBlockToolCall.vue`）；历史 Artifact 的复制按钮同样走 `DcCopyButton`（`LegacyArtifactSource.vue`）；整条消息复制由 `MessageItemAssistant` 的 `copyText` computed 提供，供 `MessageToolbar` 使用。
- **测试覆盖（静态确认，未运行）**：`test/renderer/components/message/` 下 12 个组件测试（`MessageItemAssistant.test.ts`、`MessageBlockToolCall.test.ts`、`MessageBlockContent.test.ts`、`MessageBlockThink.test.ts`、`MessageBlockActivityGroup.test.ts`、`MessageBlockMedia.test.ts`、`LiveDelegationToolCallCard.test.ts` 等）；解析侧有 `useArtifacts.test.ts`、`MarkdownRenderer.test.ts`、`MessageListRow.test.ts`。未发现长会话/大数据量的虚拟化性能基准测试。
- 视觉表现、键盘可用性与长会话滚动性能均未运行验证（见 §9）。

## 9. 边界与未验证事项

- 历史 Artifact 兼容视图不执行任何脚本/HTML；其安全边界是“只当文本渲染”，未做恶意历史内容的显示验收。
- MCP App 与工作区文件预览的 iframe 隔离强度（sandbox 组合、CSP、`workspace-preview://` 资源定位）未通过浏览器或桌面运行验证；这两条链路的细节见生成式输出与运行时笔记 §5、§7.1。
- 流式未闭合标签和节点虚拟化依赖 markstream-vue/stream-monaco 版本行为，本次未运行极长消息、快速切换 session 或移动端布局。
- assistant block 的 metadata 可表示 permission、question 和历史 plan，但本次未逐个追踪这些交互组件的可访问性与错误降级。
- 新增 block 类型的三层修改点（§7）为静态确认；未实际运行一次"新增类型"的开发流程验证遗漏面。
- 未运行项目测试、构建或 UI 截图验证；记录来自静态源码。

## 10. 关键源码索引

- assistant block 类型与 metadata：`src/shared/chat.d.ts:102-231`
- assistant 分发与 activity group：`src/renderer/src/components/message/MessageItemAssistant.vue:34-141`、`src/renderer/src/components/message/MessageBlockActivityGroup.vue`
- 权限结果徽标：`src/renderer/src/features/chat-page/model/displayMessage.ts:262`、`MessageBlockToolCall.vue:63-70`
- search 块：`src/renderer/src/components/message/MessageBlockSearch.vue`、`messageActivityGroups.ts:53`
- tool call 展示：`src/renderer/src/components/message/MessageBlockToolCall.vue:24-70`、`:360-620`
- thinking/artifact/tool 标签解析：`src/renderer/src/composables/useArtifacts.ts:58-110`、`:284`
- content block 与历史 Artifact 兼容视图：`src/renderer/src/components/message/MessageBlockContent.vue:26-33`、`LegacyArtifactSource.vue`
- Markstream 流式/虚拟化参数：`src/renderer/src/components/markdown/MarkdownRenderer.vue:217-257`
- block 类型三层定义：`src/shared/chat.d.ts:102-163`、`src/shared/contracts/common.ts:566`、`src/renderer/src/features/chat-page/model/displayMessage.ts:147-159`
- 消息窗口化与滚动（交接 Chat 笔记 §4）：`src/renderer/src/components/chat/MessageList.vue`、`useMessageWindow.ts`、`useMessageVirtualization.ts`
- 活动组：`src/renderer/src/components/message/messageActivityGroups.ts:138`、`MessageBlockActivityGroup.vue`
- 剩余执行面隔离：`src/main/mcp/apps/sandboxProtocol.ts`、`src/renderer/src/components/sidepanel/viewer/WorkspacePreviewPane.vue:47-157`
- 渲染相关测试：`test/renderer/components/message/`、`test/renderer/components/MarkdownRenderer.test.ts`、`test/renderer/composables/useArtifacts.test.ts`
