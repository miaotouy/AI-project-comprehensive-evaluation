# LobeHub 消息渲染调查笔记

> 调查对象：`E:\works\git\lobehub`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`3b57a07e3cc1f6b5aaabad36112e8ba40142df29`（分支：`canary`）
>
> 调查方式：只读源码梳理；未修改 LobeHub 仓库
>
> 调查范围：消息模型、Markdown/富文本、流式更新、列表和扩展渲染机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 先把数据库中的扁平消息重建成语义化的会话流，再按消息角色、assistant 工作流、推理、工具、附件和错误状态分别投影到 UI。Markdown 负责其中的正文节点，整个界面同时呈现 Agent 的执行过程。

主链如下：

```text
ChatStore 原始消息
  -> ConversationProvider（会话级 Zustand Store）
  -> conversation-flow.parse（重建消息树和虚拟消息）
  -> ChatList（只消费消息 ID）
  -> virtua 虚拟列表
  -> MessageItem（按 role 分派）
  -> User / Assistant / AssistantGroup / Tool / Task ...
  -> Markdown、Reasoning、附件、工具 renderer
```

Lobe 的复杂度主要来自消息语义和 Agent 工作流建模，Markdown 只是其中一个叶子渲染器。

## 1. 目录与职责分层

与消息渲染直接相关的目录可以分成五层：

| 层 | 主要目录 | 作用 |
|---|---|---|
| 页面接入 | `src/routes/(main)/agent/features/Conversation/` | 取当前 agent/topic 的消息并挂载聊天区域 |
| 会话状态 | `src/features/Conversation/`、`store/` | 为一个 conversation 建立局部状态和 actions |
| 消息整形 | `packages/conversation-flow/` | 将数据库消息转成 display message / assistantGroup |
| 消息组件 | `src/features/Conversation/Messages/` | 按 role、block、tool 具体渲染 |
| Markdown | `src/features/Conversation/Markdown/`、`@lobehub/ui` | 正文、推理和自定义标签的解析与展示 |

Messages 目录约有 156 个非测试源文件，Markdown 约 52 个，会话流包约 18 个；核心消息链合计约 2.35 万行源码。代码规模与后文的职责分布一致：渲染链覆盖的范围远超 chat bubble 本身。

## 2. 页面从哪里开始

主聊天页面入口是：

`src/routes/(main)/agent/features/Conversation/ConversationArea.tsx`

它负责以下页面级接入工作：

1. 根据 `agentId/topicId/threadId` 生成 `messageMapKey`。
2. 从全局 `ChatStore` 读取 `dbMessagesMap[chatKey]`。
3. 读取当前 operation 状态，供生成中、工具调用中和自动滚动逻辑使用。
4. 将这些数据传给 `ConversationProvider`。
5. 挂载 `ChatList`、输入框、消息转发和 topic 相关辅助组件。

这个设计把“页面业务”和“消息列表渲染”分开了：页面知道当前是哪一个会话，消息组件不需要知道路由结构。

## 3. ConversationProvider：一份会话一份局部 Store

入口：

`src/features/Conversation/ConversationProvider.tsx`

ConversationProvider 以此前生成的 messageMapKey 为 key，创建一个独立的 Conversation Store。Store 里主要有：

- `dbMessages`：当前会话的原始消息。
- `displayMessages`：给 UI 展示的虚拟/扁平消息。
- generation、editing、selection、scroll 等 UI 状态。
- 处理消息编辑、删除、分支切换、工具审批等 actions。

Store 的创建逻辑在：

`src/features/Conversation/store/action.ts`

外部消息进入 Store 后会调用解析入口取得展示列表。后续消息变更也会再次解析，并通过引用稳定化保留深度相等节点的旧引用；相关实现见上面的 action.ts 和 stabilizeReferences.ts。

`src/features/Conversation/store/slices/data/action.ts`

`src/features/Conversation/store/slices/data/stabilizeReferences.ts`

这解释了为什么代码同时存在全局 `ChatStore` 和局部 `ConversationStore`：全局 Store 管理多个会话和 Agent runtime，局部 Store 为当前渲染面提供更细粒度的订阅。

## 4. conversation-flow：渲染前的消息编译器

核心入口：

`packages/conversation-flow/src/parse.ts`

它把后端返回的扁平消息处理成三类结果：

1. `messageMap`：按 ID 快速查找原消息。
2. `contextTree`：用于上下文关系和分支导航。
3. `flatList`：给虚拟列表消费的展示顺序。

内部大致分三步：

```text
Indexing     建立 parent、branch、tool result 等索引
Structuring  把扁平 parentId 关系重建成树
Transformation 按业务规则生成虚拟消息和分组
```

`assistantGroup` 是工作流展示中的关键虚拟角色。例如下面的数据库消息：

```text
assistant: “我先检查文件”
tool:     searchFiles(...)
assistant: “找到了相关文件”
tool:     readFile(...)
assistant: “结论是……”
```

UI 中通常不会显示成五个互相独立的气泡，而是转换成一个 assistantGroup；该分组的 children 保存多个 AssistantContentBlock。

类型定义在：

`packages/types/src/message/ui/chat.ts`

## 5. ChatList 和 virtua：列表只负责显示窗口

入口：

`src/features/Conversation/ChatList/index.tsx`

ChatList 首先处理 fetch、loading、welcome、刷新失败和后台错误。消息真正显示时，它只取：

```ts
displayMessageIds: string[]
```

然后交给：

`src/features/Conversation/ChatList/components/VirtualizedList.tsx`

这里使用 virtua 的 VList，并处理聊天特有的滚动行为：

- 动态高度和底部自动跟随。
- 用户主动滚动后不抢回 viewport。
- topic 切换时恢复滚动位置。
- 输入框浮层高度加入底部 padding。
- 流式消息保持挂载，防止 Markdown 动画重播。
- 文本选区所在消息保持挂载，避免卸载丢失 Selection。

所以列表层并不理解 Markdown，也不理解工具参数；它只负责“哪些消息行在窗口中、何时挂载”。

## 6. MessageItem：按 role 选择渲染器

入口：

`src/features/Conversation/Messages/index.tsx`

MessageItem 从会话 Store 读取指定 ID 的展示消息，然后按消息角色分派：

| role | 组件 |
|---|---|
| `user` | `Messages/User` |
| `assistant` | `Messages/Assistant` |
| `assistantGroup` | `Messages/AssistantGroup` |
| `supervisor` | 复用 `AssistantGroup`，但展示 group 身份 |
| `tool` | `Messages/Tool` |
| `task` / `tasks` / `groupTasks` | 任务视图 |
| `agentCouncil` | 多 Agent 并行视图 |
| `compressedGroup` | 压缩消息视图 |
| `verify` / `taskCallback` | 验证和回调视图 |

所有消息外面通常都会包：

- SafeBoundary：单条消息或单个 block 出错时局部降级。
- Suspense：工具 Detail、Debug、编辑状态等可以懒加载。
- MessageSelectionWrapper：多选和文本选择操作。
- ChatItem：头像、标题、气泡、操作栏和错误附加内容。
- 消息壳另有两类内容块：PendingRetryTurn（对应 `Messages/components/PendingRetryTurn.tsx`，提供错误卡重试入口）与 GoalWorkCard（对应 `Messages/GoalWorkCard/`，把任务 callback 卡与 goal 进度合并展示；goal 状态来自 operation 派生，见 `deriveOperationGoals.ts`）。
- 助手消息里 Agent 名称旁不显示 role 标签。

## 7. User 消息：Markdown 和 Lexical 二选一

入口：

`src/features/Conversation/Messages/User/components/MessageContent.tsx`

用户消息有两种内容来源：

### 普通 Markdown

没有 editorData 时，先清理 speaker tag，再通过 MarkdownMessage 渲染。

### 富文本编辑器状态

有 editorData 时，使用：

`@lobehub/editor/renderer` 的 `LexicalRenderer`

并注册 Lobe 自己的节点：

- action tag
- mention
- refer topic
- local file tag

这条路径不是 Markdown 解析，而是直接从 Lexical 的 serialized editor state 恢复节点树。

另外，用户消息可以同时挂载 page selection、图片、视频、音频和文件列表。音频播放器位于独立 feature `src/features/AudioPlayer/`，`Messages/User/components/` 下保留 `AudioFileListViewer.tsx` 做附件列表。

## 8. Assistant 消息：正文、推理、搜索和附件并列

入口：

`src/features/Conversation/Messages/Assistant/components/MessageContent.tsx`

Assistant 的内容顺序通常是：

```text
drawer / HTML 预览入口
  -> 搜索引用和图片结果
  -> RAG file chunks
  -> Reasoning
  -> 正文 Markdown 或多模态 parts
  -> 图片列表
```

正文由 `DisplayContent` 决定：

`src/features/Conversation/Messages/components/DisplayContent.tsx`

- `LOADING_FLAT`：显示生成中占位。
- 工具调用正在生成且没有正文：不显示重复正文。
- `metadata.isMultimodal`：通过 deserializeParts 拆成文本和图片。
- 普通文本：走 Markdown。

Reasoning 单独由 Thinking 组件展示，默认是可折叠、可自动滚动的区域：

`src/features/Conversation/Messages/components/Reasoning.tsx`

仅签名的空 reasoning 卡不显示。

## 9. AssistantGroup：把工作过程折叠起来

入口：

`src/features/Conversation/Messages/AssistantGroup/components/Group.tsx`

语义分段在：

`packages/conversation-flow/src/assistantGroupContent.ts`

每个 assistant block 会被分类为：

- `answer`：最终答案。
- `workflow`：推理、状态文本和工具执行过程。

已完成的 workflow 默认折叠为一个“已处理”区域；生成中则显示工作状态、耗时、工具数量和审批状态。多工具 workflow 进入 WorkflowCollapse，单工具 workflow 可能以内联形式显示。

工作流折叠在可见输出结束处收口：ContentBlock 跳过空 content block 占位，Group 折叠到可见输出末端，与正文输出同时进行的工作流展示不会拖到工具回合全部结束。

`ContentBlock` 再对一个 block 做叶子分派：

```text
Reasoning
  -> Markdown 正文
  -> ImageFileListViewer
  -> Tools
  -> Error
```

这个分组层是 Lobe 和普通 Chat UI 最大的区别：它需要表达“模型说了什么”和“模型为了得到答案做了什么”之间的关系。

以上细节均为静态代码核对（证据集中在消息组件目录和 conversation-flow 的解析入口）；视觉效果与动画行为未运行验证。

## 10. Markdown 的两条路径

应用包装组件：

`src/features/Conversation/Markdown/index.tsx`

它从用户设置读取字体、Shiki theme、Mermaid theme，再调用 @lobehub/ui 的 Markdown 组件。

### 静态路径

历史消息和非生成中的内容走 `react-markdown`。在 Lobe UI 内部，Markdown 处理链大致是：

```text
remark-parse
  -> remark plugins（GFM、CJK、math、breaks、custom tags）
  -> remark-rehype
  -> rehype plugins（raw、KaTeX、footnotes、alerts）
  -> React components
```

### 流式路径

生成中且用户启用 fade-in 时，Lobe UI 使用自己的 StreamdownRender：

```text
remend 修补不完整 Markdown
  -> marked.lexer 按 block 切分
  -> 自适应平滑输出
  -> 只重渲染变化中的尾部 block
  -> 每个 block 使用缓存的 unified processor
  -> rehypeStreamAnimated 做字符/单词动画
```

应用层的选择逻辑在：

`src/features/Conversation/Messages/useChatMarkdown.tsx`

用户消息则显式设置 `enableStream: false`，避免用户输入历史被当作模型流式输出。

## 11. Lobe 自定义 Markdown 标签

插件注册表：

`src/features/Conversation/Markdown/plugins/index.ts`

当前主要有：

- assistant：`think`、`lobeArtifact`、`lobeThinking`、`lobeAgents`、搜索引用、local file。
- user：mention、skill、tool、task、user feedback。
- all：内部链接和 local file link。

每个插件可以提供：

- remarkPlugin：把文本/HTML 标签转换成自定义 mdast 节点。
- rehypePlugin：在 hast 阶段识别或改写节点。
- Component：最终的 React 展示组件。

例如 processWithArtifact() 会先整理 artifact 和 thinking 标签，避免模型输出中的换行让 Markdown AST 把 artifact 拆成普通文本。

## 12. 代码块、Mermaid 和 HTML artifact

@lobehub/ui 的 Markdown component override 会把 `<pre>` 交给代码块路由器：

- 普通代码：Shiki 高亮。
- 流式代码：Shiki token 流式渲染。
- `mermaid`：Mermaid SVG 渲染。
- 完整 `html` 文档：HTML preview iframe。
- 单行短代码：轻量 inline 预览。

HTML 预览默认使用 sandbox：

```text
allow-scripts allow-forms allow-modals
```

刻意不包含 `allow-same-origin`，避免模型生成的脚本读取父页面的 cookie、localStorage 或桌面端 IPC 边界。完整 HTML 才会进入 iframe，普通 HTML 片段继续按代码展示。

## 13. 工具渲染注册表

AssistantGroup 的工具入口：

`src/features/Conversation/Messages/AssistantGroup/Tool/index.tsx`

一个工具至少有四种状态：

1. 参数仍在流式生成。
2. 等待执行或等待审批。
3. 正在执行。
4. 已完成、拒绝、中止或报错。

工具 UI 从 @lobechat/builtin-tools 注册表查询：

```text
identifier + apiName
  -> inspector（标题和状态）
  -> streaming renderer（执行中）
  -> custom renderer（完成结果）
  -> fallback argument/result renderer
```

注册代码在：

`packages/builtin-tools/src/register.ts`

工具相关代码因此分散在多个 builtin-tool-* 包中：消息组件只负责生命周期和布局，具体工具业务由工具包提供。

## 14. 性能设计和代价

### 已经做的优化

- virtua 虚拟列表，避免所有消息同时参与布局。
- memo + fast-deep-equal，阻止无关消息重渲染；该策略是组件级手工斟酌的，不是统一约定（仓库曾移除大量“无效 memo 边界”，涉及 101 个文件、约 500 行）。
- stabilizeReferences，给解析后未变化的节点恢复旧引用。
- 工具按 tool-call ID 单独订阅，兄弟工具不会因参数变化全部刷新。
- 流式消息和文本选区消息 `keepMounted`。
- 工具 Detail/Debug 使用 dynamic import 和 Suspense。
- Markdown 流式处理只重点更新尾部 block。
- 每个消息、block、tool 都有局部 ErrorBoundary。

### 仍然存在的基础成本

- 每次消息 dispatch 都会重新跑 conversation-flow 的解析入口。
- 解析会重建完整树，再做结构共享恢复。
- Markdown、工具 workflow 和列表滚动分别维护自己的状态机。
- 全局 ChatStore 与局部 ConversationStore 之间需要同步。
- 工具注册表和大量内置工具会扩大前端依赖图。

这些基础成本既来自代码组织，也来自产品能力叠加：多轮工具、审批、推理、多 Agent、任务、artifact、附件、分支和流式动画都共用同一条渲染链。

## 15. 如果只想学习或复用消息渲染

阅读这套渲染链时，可按以下顺序定位文件：

1. [ConversationArea.tsx](E:/works/git/lobehub/src/routes/(main)/agent/features/Conversation/ConversationArea.tsx)：看页面如何接入消息。
2. [ConversationProvider.tsx](E:/works/git/lobehub/src/features/Conversation/ConversationProvider.tsx)：看会话级 Store 如何建立。
3. [parse.ts](E:/works/git/lobehub/packages/conversation-flow/src/parse.ts)：理解为什么 UI 消息和数据库消息不同。
4. [ChatList/index.tsx](E:/works/git/lobehub/src/features/Conversation/ChatList/index.tsx)：理解列表边界。
5. [Messages/index.tsx](E:/works/git/lobehub/src/features/Conversation/Messages/index.tsx)：理解 role 分派。
6. [Assistant/components/MessageContent.tsx](E:/works/git/lobehub/src/features/Conversation/Messages/Assistant/components/MessageContent.tsx)：理解普通 assistant 正文。
7. [AssistantGroup/components/Group.tsx](E:/works/git/lobehub/src/features/Conversation/Messages/AssistantGroup/components/Group.tsx)：理解工具工作流折叠。
8. [useChatMarkdown.tsx](E:/works/git/lobehub/src/features/Conversation/Messages/useChatMarkdown.tsx)：理解 Markdown 配置。
9. [Markdown/plugins/index.ts](E:/works/git/lobehub/src/features/Conversation/Markdown/plugins/index.ts)：理解 Lobe 私有标签。
10. `@lobehub/ui` 的 `src/Markdown/Markdown.tsx` 和 `src/Markdown/SyntaxMarkdown/StreamdownRender.tsx`：理解静态/流式 Markdown 的具体实现。

如果只做一个轻量聊天产品，通常只需要：

```text
UI message type
  -> user / assistant 分派
  -> Markdown
  -> optional reasoning
  -> optional structured tool parts
```

不需要直接复制整个 `Conversation` feature；只有要兼容 Lobe 的历史消息 parent-child 结构和 assistantGroup 语义时，才值得引入 `conversation-flow`。
