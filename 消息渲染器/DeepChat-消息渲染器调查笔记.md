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

1. assistant block 用枚举区分正文、搜索、推理、计划、错误、工具调用、动作、图片、音频与历史 artifact-thinking 十种类型；状态和工具/权限 metadata 分开保存，计划与 artifact-thinking 只作为历史消息的兼容形态保留。
2. `MessageItemAssistant` 按活动组、正文、推理、工具调用、动作、媒体与错误依次分发；推理与工具块可折叠，工具卡能展示参数、响应、图片、diff 和 MCP App 视图。
3. 正文块先用 `useArtifacts` 解析三类内联标签，分别是推理标记 `<antThinking>`、artifact 标记 `<antArtifact>` 与历史的 `<tool_call>`，流式中未闭合的标签也能兼容；解析出的 artifact 交给历史 Artifact 兼容视图，只显示标题与可复制的原文。
4. Markdown 正文由 markstream-vue 渲染，代码块交给 stream-monaco 的 Monaco surface；流式与静态内容使用不同的 render batch、viewport priority 与节点虚拟化参数，静态长文因此可以虚拟化，流式输出保持平滑。
5. 历史 Artifact 的六种 type 统一按原文展示；随 Artifact 功能退役，内建的 HTML/React iframe、SVG sanitizer 与 Mermaid 清洗渲染链一并移除，普通 Markdown 改用 markstream-vue 的 HTML 安全策略。
6. Markstream 渲染路径使用独立的流式 diff 工作池；压缩边界由消息列表的一行专用分隔行表达，不进入 assistant block 分发（`src/renderer/src/lib/markstreamLanguage.ts`、`src/renderer/src/components/chat/MessageListRow.vue`）。
7. 相邻的推理块与工具调用块在结算后可折叠成一个 activity group，仍在流式输出的行保持逐块显示；分组只改变展示层的投影，持久化的 block 顺序保持不变。

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

`AssistantMessageBlock` 以类型、内容、状态和时间戳为基本字段，再按 block 类型附加 artifact 描述、工具调用的参数与响应、图片预览、图片数据和推理耗时。与之并列的 `AssistantMessageExtra` 记录工具来源、权限请求、提问、子代理进度，以及 `max_tool_calls`、`max_tokens` 超限时的跳过原因。两处定义见 `src/shared/chat.d.ts:102-163` 与 `:177` 起。

`MessageItemAssistant.vue:34-141` 的分发顺序为：activity 组（推理/工具）、MCP app、content、reasoning/artifact-thinking、provider search、tool call、提问与一般 action、音频/视频、图片、错误。activity group 内部在 `MessageBlockActivityGroup.vue` 再分派 Think 与 ToolCall，并显示推理/工具数量和耗时。

`buildAssistantRenderItems`（`src/renderer/src/components/message/messageActivityGroups.ts:138`）会把相邻的 reasoning/tool-call 块缓冲成活动组；只有一个块时保持原组件，多个块才生成稳定 group key。当前正在流式的消息行保持未分组，以便实时显示活动变化；折叠后仍保留子项的展开状态和焦点回迁（`MessageItemAssistant.vue:486-548`）。

`MessageBlockThink` 把 reasoning time 换成耗时标签，并记住折叠状态。工具卡组件按 block 状态在 running、reviewing、error 之间切换状态环、徽标与图标，展示服务器标识、参数与响应、图片预览、diff 和 MCP App 结果，展开与图标规则集中在 `MessageBlockToolCall.vue:24-70`、`:360-620`。

工具卡在加载中可按工具类型自动展开，用户主动收起后会暂停自动展开；这类规则只改变展示状态，数据类型不变（[展开判断与状态同步](<../../deepchat/src/renderer/src/components/message/MessageBlockToolCall.vue#L572-L616>)、[自动展开守卫](<../../deepchat/src/renderer/src/components/message/MessageBlockToolCall.vue#L710-L733>)）：

- process 与子代理编排工具在加载中满足自动展开条件。
- `exec` 及同类的 skill_run 还需已解析出参数，并满足以下任一条件：后台执行标记为真，或 `timeoutMs` 至少为 10000。

另有两条分发规则（源码确认）：

- **provider search 块**：被判为 provider 搜索的 search 块改由 `MessageBlockSearch.vue` 渲染，只接受 search、open_page 与 find_in_page 三种动作类型。该块显示动作链接、来源页面列表和状态图标，数据来自 DeepSeek 原生 web 搜索的 `providerSearch` 与 `providerUrlSource` 流事件（见 §2），分发点在 `MessageItemAssistant.vue:88`。
- **权限结果徽标**：工具卡上显示权限结算结果的 granted 或 denied 徽标（#2132）。权限结算完成后，展示层按 `tool_call.id` 把权限 action 块映射到同一列表中的工具卡，映射成功时独立 action 卡被过滤，只有找不到对应工具卡时才保留为兜底。徽标与映射入口见 `MessageBlockToolCall.vue:63-70`、`displayMessage.ts:262`，过滤点在 `MessageItemAssistant.vue:527-543`。

## 2. Content 与历史标签解析

`useBlockContent` 把 content 字段解析成 `ProcessedPart[]` 片段数组，这条链由 `useArtifacts.ts:37` 的调用入口、`:58` 起的正则集合与 `:284` 的片段生成函数组成：

- 推理标签 `<antThinking>` 同时支持闭合写法与流式未闭合写法；
- artifact 标签 `<antArtifact type="..." identifier="..." title="...">` 的 type、identifier、title 取自开标签属性，闭合与未闭合两种形式都能解析；
- 工具类标签按出现顺序依次处理，避免前缀相同的标签抢先匹配，涉及以下五个：

  ```text
  <tool_call>
  <tool_response>
  <tool_call_end>
  <tool_call_error>
  <maximum_tool_calls_reached>
  ```

解析结果区分 text/thinking/artifact/tool_call，并携带 loading、tool status、artifact type/language。流式状态下，未闭合的 tool/artifact 部分会保留到下一次 content 更新；`MessageBlockContent.vue:66-70` 消费 `useBlockContent` 的输出，artifact part 交给 `LegacyArtifactSource`（`:26-33`），没有 artifact store 同步。

**search 块的流式来源**：主进程的 AI SDK 流适配器把 DeepSeek Responses 返回的 raw 与 source 流部件投影成 provider 搜索事件和来源 URL 事件，只接受 http/https 来源，去重后的来源数量上限为 100 个。事件随后被组织成 search 类型的 block 落盘，交给 §1 的搜索块组件渲染，显示形态由 actionType 的三种取值决定。这条链只服务 provider 原生搜索，当前接入的是 DeepSeek `deepseek-v4-flash`，与历史标签解析无关。适配器实现见 `src/main/provider/aiSdk/streamAdapter.ts:111-200`。

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

- **MCP App**：代理页由主进程的 sandboxProtocol 生成，界面采用双层 iframe 并配动态 CSP，由 `McpAppView.vue` 承载（详见生成式输出与运行时笔记 §7.1）。生成入口见 `src/main/mcp/apps/sandboxProtocol.ts`。
- **工作区文件预览**：HTML、SVG 与 PDF 经自定义的 workspace-preview 协议进入 iframe，sandbox 使用 `allow-scripts allow-same-origin` 组合，SVG 另有独立预览组件。入口见 `WorkspacePreviewPane.vue:47`、`:157` 与 `WorkspaceSvgPreview.vue`。
- **普通 Markdown**：沿用 markstream-vue 的安全 HTML policy；工具响应里的图片与 diff 由独立组件和状态处理。
- 外部网络请求与 CSP 配置未逐条追查到应用打包层；`deepcdn://` 协议仍注册，本次未找到使用方（生成式输出与运行时笔记 §4）。

## 6. 消息列表、窗口化与滚动

消息列表按窗口分段渲染，列表与行组件只接收当前窗口内的消息项。窗口计算以估算高度为基础，配合 ResizeObserver 实测、首尾占位元素和逻辑锚点维持滚动位置；消息数超过阈值后改用二分查找定位视口附近的索引范围，ChatPage 在切换会话与追加消息后保存并恢复测量快照。该主题与 Chat 笔记 §4「消息窗口化」描述同一实现，本笔记只记录交接点，入口见 `MessageList.vue:1-65`、`useMessageWindow.ts`、`useMessageVirtualization.ts`（均在 `src/renderer` 下）。

## 7. 扩展方式与已确认边界

新增 block 类型需要同时修改三层，未发现插件式注册表：

1. **持久化类型**：`AssistantMessageBlock.type` 联合定义在 `src/shared/chat.d.ts:102-163`，新增类型要在这里补上取值。
2. **IPC 契约**：对应的 zod schema 用枚举校验 type，跨进程校验落在这一层，见 `src/shared/contracts/common.ts:566`；block 的 status 枚举另含 granted 与 denied，权限结果的持久化形态由它们表达（§1 徽标的数据来源）。持久化层的 type 取值如下：

   ```text
   content / search / reasoning_content / plan / error / tool_call / action / image / audio / artifact-thinking
   ```
3. **展示层**：展示层的 block 类型比持久化层多出 video，由转换逻辑派生；渲染前还要过一遍可渲染性过滤，plan、空内容与内部工具调用在此被丢弃，随后进入 §1 的分发链。类型定义与过滤条件见 `src/renderer/src/features/chat-page/model/displayMessage.ts:147-159`、`:294`。

已确认边界：plan 与内部工具调用块在渲染前被过滤掉；action 类型按动作值分发到专用组件，tool_call_permission 走审批、question_request 走提问、rate_limit 走限流提示。新增类型若只存在于展示层（如 video、audio 这类媒体），只需补持久化转换与分发组件，IPC schema 不必改动。plan 与 artifact-thinking 属历史形态：前者继续被可渲染性过滤挡住，后者仍按 reasoning 样式折叠显示。过滤条件、动作取值与历史类型的定义见 `displayMessage.ts:294`、`chat.d.ts:150-155`。

## 8. 性能、缓存与测试

- **缓存策略**：正文解析带一份 last-parse memo，流式期间同一字符串重复解析时直接返回缓存结果（`useArtifacts.ts:118` 起）。内容块先比较快照再决定是否更新解析结果（`MessageBlockContent.vue:66-90`），Markdown 侧则区分流式与静态两套 batch 参数和节点虚拟化（§3）。
- **历史 Artifact 解析缓存**：解析结果按 block 引用记忆，消息行重新渲染时复用已有对象；这一优化依赖 block 引用保持不变的约定，入口见 `src/renderer/src/composables/useArtifacts.ts`。
- **非视觉模式**：应用开启 accessibility support 后，ChatPage 关闭消息窗口化，消息区变成可聚焦区域；折叠组与工具卡补上 `aria-expanded` 与 `aria-controls` 属性。以上来自静态接线，屏幕阅读器的实际播报顺序尚未运行验证。
- **渲染频率**：主进程按 120ms 节流推送全块快照（`chat.stream.updated` 事件），数据库落盘按 600ms 节流，两个节奏都由生成侧控制（`src/main/agent/deepchat/runtime/echo.ts:6-7`，详细链路见生成式输出与运行时笔记 §2 与 Chat 笔记 §3），本笔记不再展开。
- **复制按钮**：工具卡的参数与响应复制、历史 Artifact 的原文复制都复用 `@dc-ui` 的复制组件；整条消息的复制由 `MessageItemAssistant` 的 copyText 计算属性提供，挂在 `MessageToolbar` 上。组件落点见 `MessageBlockToolCall.vue` 与 `LegacyArtifactSource.vue`。
- **测试覆盖（静态确认，未运行）**：`test/renderer/components/message/` 下有 12 个组件测试，下列七份覆盖消息项分发、工具卡、内容块、推理块、活动组、媒体块与委派工具卡：

  ```text
  MessageItemAssistant.test.ts
  MessageBlockToolCall.test.ts
  MessageBlockContent.test.ts
  MessageBlockThink.test.ts
  MessageBlockActivityGroup.test.ts
  MessageBlockMedia.test.ts
  LiveDelegationToolCallCard.test.ts
  ```

  解析与渲染侧另有三个测试文件，分别对应 useArtifacts、MarkdownRenderer 与 MessageListRow。未发现长会话或大数据量的虚拟化性能基准测试。
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
