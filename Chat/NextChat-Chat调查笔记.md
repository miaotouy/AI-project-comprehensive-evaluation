# NextChat Chat 调查笔记

> 调查对象：`E:\works\git\NextChat`（重点 `app/components/home.tsx`、`app/components/chat.tsx`、`app/store/chat.ts`、`app/utils/store.ts`）
>
> 调查更新日期：2026-08-06
>
> 代码快照：`706a18b95b714ab29b2a4842d3b9ff4f887935d5`（分支：`main`）
>
> 调查方式：只读源码梳理；未修改 NextChat 仓库
>
> 调查范围：聊天会话、消息状态、存储、流式更新与交互机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

NextChat 的聊天实现是“Zustand 持久化会话 + 客户端请求编排 + 单页消息窗口”，没有服务端 conversation runtime：

1. `useChatStore` 以 `ChatSession[]` 保存会话、消息、Mask、记忆摘要和上下文截断索引；store 默认使用 IndexedDB，异常时回退到 localStorage。
2. 用户发送消息后，客户端先填充输入模板和图片，再按 system prompt、长期摘要、Mask context、短期历史和新消息的顺序组装请求。assistant 消息先以 `streaming` 占位写入 store，SSE 回调不断原地更新它。
3. 工具调用和 MCP 回注都发生在同一聊天状态机内：普通插件工具由 provider adapter 执行并重新请求，MCP 结果以特殊用户消息再进入 `onUserInput`。
4. 长对话采用两种压缩：`historyMessageCount`/`max_tokens` 负责每次请求的短期窗口，`memoryPrompt` 负责超过阈值后的摘要；首次达到 50 个估算词时还可单独生成会话标题。
5. UI 不做真正的虚拟列表，而是对 `renderMessages` 做窗口分页：默认显示末尾 15 条，并在滚动时按 15 条增减，最多一次取 3 页。会话列表支持拖拽排序、删除撤销和 fork。

## ASCII 调用链图

```text
Home
  -> useLoadData() 获取当前 provider 模型
  -> fetch /api/config 获取服务端能力
  -> Router -> Chat / NewChat / Masks / Settings

Chat 输入
  -> doSubmit -> useChatStore.onUserInput
     -> fillTemplateWith + multimodal images
     -> getMessagesWithMemory
        system -> long memory -> Mask.context -> recent history -> user
     -> 保存 user message + streaming assistant placeholder
     -> getClientApi(provider).llm.chat
        -> SSE onUpdate / onBeforeTool / onAfterTool / onFinish
     -> updateTargetSession
     -> onNewMessage -> 统计、MCP 检测、自动标题/摘要

Chat UI
  -> session.mask.context + session.messages
  -> 分页窗口（CHAT_PAGE_SIZE = 15）
  -> message role / streaming / tools / attachments
  -> Markdown、图片、音频和工具状态
```

## 1. 页面入口和持久化状态

### 1.1 页面初始化

`app/components/home.tsx:160-220` 负责根据路由渲染 Chat、NewChat、Mask、Plugin、Settings、MCP market 和 Artifact 页面。`useLoadData` 在首屏用当前 provider 的 `api.llm.models()` 拉取模型并合并到 app config（`app/components/home.tsx:223-235`）。

`Home` 首次 effect 还会：

- 调用 `useAccessStore.fetch()` 获取服务端配置；
- 在 `ENABLE_MCP=true` 时初始化 MCP client；
- 等待 `useHasHydrated()` 后再进入 Router（`app/components/home.tsx:237-271`）。

### 1.2 Store 存储层

`createPersistStore`（`app/utils/store.ts:29-77`）在所有 Zustand persist store 上强制使用 `indexedDBStorage`。`IndexedDBStorage`（`app/utils/indexedDB-storage.ts:7-47`）的行为是：

1. 读取时优先 `idb-keyval.get(name)`，没有值或出错时读 localStorage；
2. 写入时先解析 persist JSON，hydration 未完成则跳过，正常写入 IndexedDB；
3. IndexedDB 失败时写 localStorage；删除和 clear 也有同样回退。

Chat store 的 persist key/version 位于 `app/store/chat.ts:861-868`，当前版本为 `3.3`。这意味着消息历史默认留在浏览器本地，不由 Next.js 服务端保存。

## 2. ChatSession 和消息模型

`app/store/chat.ts:44-120` 定义了核心数据：

```text
ChatMessage
  id / date / role / content
  streaming? / isError? / model?
  tools? / audio_url? / isMcpResponse?

ChatSession
  id / topic
  messages: ChatMessage[]
  stat: tokenCount / wordCount / charCount
  lastUpdate / lastSummarizeIndex
  clearContextIndex?
  memoryPrompt
  mask: Mask
```

`content` 可以是字符串，也可以是 `text + image_url` 的多模态数组；`tools` 保存当前 assistant 产生的工具调用状态。`createEmptySession` 建立一个空会话、空记忆和空 Mask（`app/store/chat.ts:104-120`）。

### 2.1 会话操作

- `newSession(mask?)`：新建空会话；如果传入 Mask，合并全局模型配置，设置 topic 为 Mask 名称（`app/store/chat.ts:307-328`）。
- `forkSession()`：深拷贝当前消息并为每条消息生成新 id，同时复制 Mask/modelConfig（`app/store/chat.ts:243-267`）。
- `deleteSession()`：删除会话；删除最后一个时自动补回空会话，并通过 toast 提供 5 秒撤销（`app/store/chat.ts:337-378`）。
- `moveSession()`：移动数组位置并修正当前索引（`app/store/chat.ts:282-305`）。
- `resetSession()`：清空消息和 memoryPrompt，但保留会话与 Mask（`app/store/chat.ts:654-659`）。

`ChatList` 用 `react-beautiful-dnd` 接收拖拽结果，再调用 `moveSession`；点击列表项导航到 Chat 并设置当前索引（`app/components/chat-list.tsx:105-174`）。

## 3. 一次发送的请求编排

### 3.1 输入预处理和占位消息

`onUserInput`（`app/store/chat.ts:407-527`）执行以下步骤：

1. 读取当前 session 的 `mask.modelConfig`。
2. 普通输入经 `fillTemplateWith` 填入 `{{input}}`、模型、时间、语言等变量；MCP response 跳过模板。
3. 图片附件与文本合并为多模态数组。
4. 创建 user message 和 `streaming: true` 的 assistant placeholder。
5. 调用 `getMessagesWithMemory()`，把历史和新 user message 组成 `sendMessages`。
6. 先写入 user/assistant 两条消息，再从 `getClientApi(providerName)` 调用 `api.llm.chat`。

流式回调的状态边界如下：

- `onUpdate`：更新 assistant.content 并保持 `streaming=true`；
- `onFinish`：写入最终内容/date，转为非 streaming，触发 `onNewMessage`；
- `onBeforeTool`：把工具调用先追加到 assistant.tools；
- `onAfterTool`：按 tool id 替换为完整结果或错误；
- `onError`：把错误对象格式化追加到 assistant.content，设置 user/assistant 错误标记并回收 controller（`app/store/chat.ts:459-527`）。

停止和重试使用 `ChatControllerPool`，controller 在 `onController` 中注册；聊天页的 Stop action 调用 `ChatControllerPool.stop`（`app/store/chat.ts:519-526`、`app/components/chat.tsx:1143-1146`）。

### 3.2 上下文拼接顺序

`getMessagesWithMemory`（`app/store/chat.ts:542-639`）先生成可选 system prompt：对 GPT/ChatGPT 模型，如果启用 `enableInjectSystemPrompts`，把默认 system template 与 MCP 工具目录合并；只有 MCP 时也会单独发送 MCP system prompt。

随后按以下顺序构造 `recentMessages`：

```text
0. system prompt
1. long-term memory：memoryPrompt（可选）
2. Mask.context：预置示例消息
3. short-term history：从最后一条向前读取
4. 当前 user message（由 onUserInput 追加）
```

短期窗口同时受 `historyMessageCount` 和 `max_tokens` 估算限制；错误消息不会进入历史。`clearContextIndex` 会把可用起点抬高，所以能在不删除 UI 历史的情况下停止发送更早消息和摘要。

## 4. 自动标题和长期记忆

`onNewMessage` 在每次成功 assistant 消息后依次更新统计、检测 MCP JSON、调用 `summarizeSession(false, targetSession)`（`app/store/chat.ts:394-405`）。

### 4.1 自动标题

`summarizeSession` 在 `enableAutoGenerateTitle` 开启、topic 仍是默认值且估算消息长度达到 50 时，取最近的 `historyMessageCount` 条消息，加上 topic 提示词，使用非流式请求生成标题（`app/store/chat.ts:685-725`）。

### 4.2 摘要压缩

摘要流程从 `lastSummarizeIndex` 或 `clearContextIndex` 开始，过滤错误消息；若估算长度超过 `max_tokens`，只保留最近 `historyMessageCount` 条。超过 `compressMessageLengthThreshold` 且 `sendMemory` 为 true 时，追加“总结” system prompt，并使用配置的压缩模型或 `getSummarizeModel`（`app/store/chat.ts:727-795`）。成功后把返回文本写入 `memoryPrompt`，并把 `lastSummarizeIndex` 更新到当前消息长度。

这是“保留完整本地历史、请求只带摘要和最近窗口”的设计；摘要失败时只记录错误，不删除原始消息。

## 5. Chat UI 的消息窗口

### 5.1 可视消息来源

`Chat` 把 `session.mask.context` 和 `session.messages` 合并成 `renderMessages`，再根据 loading 和输入预览追加临时消息（`app/components/chat.tsx:1333-1384`）。`hideContext` 为 true 时只隐藏 context 的可视部分，发送逻辑不受影响。

窗口分页使用 `CHAT_PAGE_SIZE = 15`（`app/constant.ts:914`）：

- 初始索引定位到末尾 15 条；
- 每次返回 `msgRenderIndex` 起始的最多 `3 * CHAT_PAGE_SIZE` 条；
- 滚动触及顶部/底部时按 15 条移动；
- 到底时恢复末尾窗口并自动滚动。

这是轻量的分页窗口，而不是 `react-window`/`virtua` 一类的虚拟列表；消息仍然保存在整个 session 数组中。

### 5.2 消息操作和附件

`app/components/chat.tsx:1771-2040` 对每条消息渲染：

- user/assistant/system avatar 和模型名；
- stop、retry、delete、pin、copy、TTS 等操作；
- 工具调用状态列表；
- Markdown 正文；
- 一张或多张图片；
- `audio_url` 音频控件；
- context 分隔和日期。

assistant 的 `tools` 状态不单独建消息节点，而是挂在 assistant 消息下面；因此工具工作流和最终正文共享一个消息容器。

## 6. 跨状态合并和同步观察

`app/utils/sync.ts:33-145` 为 Chat、Access、Config、Mask、Prompt 定义本地/远端状态 getter、setter 和合并策略：

- Chat 按 session id 合并，按 message id 去重，再按 date 升序；会话按 `lastUpdate` 降序。
- Prompt/Mask 采用远端字段与本地字段合并，本地同名键覆盖远端。
- Config/Access 使用 `mergeWithUpdate`。

`mergeWithUpdate` 的实现（`app/utils/sync.ts:148-165`）把 `remoteUpdateTime` 也取成 `localState.lastUpdateTime`：

```ts
const localUpdateTime = localState.lastUpdateTime ?? 0;
const remoteUpdateTime = localState.lastUpdateTime ?? 1;
```

这会让远端时间戳无法参与比较，疑似实现缺陷；本次只做静态检查，尚未在 WebDAV/多设备同步流程中复现。

## 7. 风险、边界和未验证事项

1. **本地数据暴露**：聊天全文、Mask、API key 和自定义配置默认落在浏览器 IndexedDB；源码没有通用加密层。
2. **摘要不是严格压缩协议**：摘要模型失败、截断或与原文不一致时仍会写入 `memoryPrompt`，没有质量校验或回滚。
3. **上下文 token 估算近似**：使用 `estimateTokenLength` 和字符串内容，无法保证与每个 provider 的真实 tokenizer 一致。
4. **工具与消息耦合**：工具参数和结果挂在 assistant message 的 `tools` 元数据上，长结果会扩大本地持久化体积；但 `getMessagesWithMemory` 主要按 `message.content` 组装后续历史，工具结果是否跨用户轮次复用需单独验证。
5. **UI 分页边界**：窗口移动和清除上下文索引同时存在，复杂滚动、超长单条消息和移动端布局需要运行时验证。
6. **同步实现待复现**：`mergeWithUpdate` 的 remote 时间变量明显可疑，但未执行实际同步测试，不能据此判断所有同步场景都会丢数据。
7. 本次未运行项目测试或浏览器交互测试；结论来自 commit `706a18b` 的源码。

## 8. 关键源码索引

- 页面路由、模型加载和 MCP 初始化：`app/components/home.tsx:160-271`
- 持久化封装和 hydration：`app/utils/store.ts:29-77`
- IndexedDB/localStorage fallback：`app/utils/indexedDB-storage.ts:7-47`
- ChatMessage/ChatSession：`app/store/chat.ts:44-120`
- fork、新建、删除、排序：`app/store/chat.ts:243-378`
- 输入、流式回调和工具状态：`app/store/chat.ts:407-527`
- system/context/memory 拼接：`app/store/chat.ts:542-639`
- 自动标题和摘要：`app/store/chat.ts:661-797`
- MCP JSON 回注：`app/store/chat.ts:826-855`
- 消息分页窗口：`app/components/chat.tsx:1333-1429`
- 消息渲染和操作：`app/components/chat.tsx:1771-2040`
- 会话列表拖拽：`app/components/chat-list.tsx:105-174`
- 跨 store 合并：`app/utils/sync.ts:33-165`
