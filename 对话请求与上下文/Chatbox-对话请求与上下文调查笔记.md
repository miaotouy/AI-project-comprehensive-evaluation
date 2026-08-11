# Chatbox 对话请求与上下文调查笔记

> 调查对象：`E:\works\git\chatbox`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`f90fc31afd634494bdf8f074eca3e38fcf8da740`（分支：`main`）
>
> 调查方式：从 [`../Chat/Chatbox-Chat调查笔记.md`](../Chat/Chatbox-Chat调查笔记.md)（2026-08-07 调查）迁移现有段落与证据，未重新调查代码
>
> 调查范围：一次生成任务的提交入口、上下文拼装、流式消费、节流落盘、停止与回写；会话数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Chatbox 的一次生成任务由输入区提交开始，最终落到 `orchestrateGeneration` 消费模型流式输出：

- **主链**：`handleSubmit` → `constructUserMessage` → `submitNewUserMessage`（写用户消息 + 插入 assistant 占位）→ `orchestrateGeneration` → `model.chatStream()` 逐 chunk 消费。
- **流式更新拆成两条频率完全不同的路径**：每个 text-delta/reasoning-delta chunk 立刻刷新 UI 缓存（几乎逐 token），但只有"距上次落盘 ≥ 2 秒"或"chunk 是 tool-call"时才真正写 storage；流结束/出错/暂停时再无条件补一次最终落盘。
- **Agent 模式、知识库、网页浏览三种"输入区上下文增强"在底层统一建模成同一个工具注册管线里的三个开关**，而不是三套独立的 prompt 拼接逻辑，每个开关受模型能力（`isSupportToolUse(scope)`）门控。
- Copilot 本质是"系统提示词模板"，选中后把 prompt 写进 `session.messages[0]`。
- 上下文入口会按模型上下文预算筛选历史；具体的 token 截断策略与 provider payload 字段属于未核实事项。

## 系统边界与生成任务主链

```text
InputBox.handleSubmit（收集文本/附件/开关状态）
  -> sessionHelpers.constructUserMessage（图片进 contentParts、文件进 files、链接进 links）
  -> submitNewUserMessage（写用户消息 -> 插入 assistant 占位 -> 进入生成）
  -> orchestrateGeneration
      -> session/utils.ts 选择当前 session 或 thread 的消息（历史选择）
      -> prepareAgentGenerationHarness / buildToolsForSession（工具注册管线）
      -> model.chatStream()（Provider 调用）
      -> 逐 chunk：updateStreamingCache（UI 缓存）或 persistStreamingMessage（落盘）
  -> 流结束/出错/暂停 -> 无条件最终落盘
```

边界：会话与消息如何持久化、分支数据结构属于会话与消息管理；发送按钮、停止按钮、排队提示等用户可见状态属于 Chat UI；消息内容如何渲染属于消息渲染器。

## 1. 提交入口、任务对象与状态机

- `InputBox.tsx:779` 的 `handleSubmit` 接收编辑器文本和附件，`InputBox.tsx:837-843` 调用 `sessionHelpers.constructUserMessage`（`sessionHelpers.ts:700-770`）：图片进入 `contentParts`（`:722-725`），文件进入 `files`（`:728-758`），链接进入 `links`（`:760-770`）。
- `stores/session/messages.ts:177` 的 `submitNewUserMessage` 先写入用户消息，随后 `:224-246` 插入 assistant 占位并由 `:308` 进入生成。
- 生成期间存在 `generating: true` 的占位消息；停止时调用其 `cancel()` 并把该消息以 `generating: false` 乐观写回（界面入口见 Chat UI 笔记）。
- 首页"假会话"首次发送时会先走 `createPersistedChatSession` 创建真实 Session 再提交（数据语义见会话与消息管理笔记 3.1）。

## 2. 历史选择与上下文拼装顺序

- `orchestrateGeneration` 通过 `session/utils.ts:105` 选择当前 session 或 thread 的消息；`agent-harness.ts:199-230` 只取目标消息之前的历史，再交给上下文构建。
- **system prompt**：Copilot 的 `prompt` 在选中时写入 `session.messages[0]`（`{ role: 'system', contentParts: [...] }`），随历史一起进入请求。
- **附件**保留在用户消息的 parts/files 字段中，随消息模型进入请求。
- **知识库、网页浏览、Agent 模式**不拼进 prompt 文本，而是作为工具注册进本次请求（见第 9 节）。

## 3. 预算、截断、摘要与压缩

- 本次源码确认的上下文入口会按模型上下文预算筛选历史；生成中的消息列表还有独立的流式缓存与持久化路径（`session/messages.ts`）。
- 摘要/压缩触发点：`stores/session/messages.ts:198-205` 调用 `runCompactionWithUIState`；具体触发代码在 `context-management` 包内——**未核实**（本次未读取该包源码）。摘要产生后以 `Message.isSummary` 标记，数据语义见会话与消息管理笔记 1.4。
- 具体 provider 侧 token 截断策略未在本次入口范围内完全核实。

## 4. SDK、Provider、模型与协议交接

- 流式生成主循环遍历 `model.chatStream` 产出的每个 chunk（`orchestration.ts:632-675`）。
- 具体各 provider payload 字段由 API 适配层生成，本笔记未逐一展开；`chat` 与 `picture` 两类会话对应不同模型集合（`lastUsedModelStore` 分字段记录）。

## 5. 流式事件、缓冲、节流与顺序

### 5.1 两条完全独立的写路径

`stores/session/messages.ts`：

- `updateStreamingCache(sessionId, message)`（`:132-137`）：只调 `chatStore.updateMessageCache` → `updateSessionCache`/`updateSessionCacheSync`（`chatStore.ts:413-432`）→ 直接 `queryClient.setQueryData` 改 react-query 缓存，**不碰 storage**，注释里写明"性能优先，不检查 session 存在性"。
- `persistStreamingMessage(sessionId, message, options)`（`:143-155`）：调 `chatStore.updateMessage` → `updateSessionWithMessages`（`chatStore.ts:350-391`），走每会话一个的 `UpdateQueue`（`stores/updateQueue.ts`，基于 `queueMicrotask` 的串行合并队列，避免并发 update 互相覆盖），**真正写 storage**。

### 5.2 节流策略：2 秒定时 + 特例立即持久化

节流判断函数 `shouldPersistStreamingChunk`（`stores/session/orchestration.ts:437-446`）：

```ts
export function shouldPersistStreamingChunk(chunkType, elapsedMs, persistInterval) {
  // Tool calls can block the stream for a long time (waiting on approval),
  // so persist them immediately instead of relying on the periodic 2s flush.
  return chunkType === 'tool-call' || elapsedMs >= persistInterval
}
```

`persistInterval` 硬编码 `2000`（`orchestration.ts:471`）。主循环（`orchestration.ts:632-675`）里：

```ts
const shouldPersist = shouldPersistStreamingChunk(chunk.type, Date.now() - lastPersistTimestamp, persistInterval)
if (shouldPersist) {
  void persistStreamingMessage(sessionId, targetMsg)   // 落盘（异步、不等待）
} else {
  updateStreamingCache(sessionId, targetMsg)            // 只刷 UI
}
```

也就是：**每个 text-delta/reasoning-delta chunk 都会立刻刷新 UI 缓存**（几乎逐 token），但只有"距上次落盘 ≥ 2 秒"或"这个 chunk 是 tool-call"时才真正写 storage。流结束/出错/暂停时还各自补一次无条件的 `persistStreamingMessage(..., { refreshCounting: true })`（`:688, 718, 739, 751, 758`），确保最终态一定落盘。

`tool-call` 被特殊处理的原因写在注释里：tool-call 可能长时间阻塞在等用户批准（`user_exec_approval`/`file_mutation_approval`/`app_action_approval`），如果不立刻持久化，用户刷新/关闭应用会丢失这个待批准状态。

### 5.3 一处疑似死代码：`throttleWriteSessionAtom.ts`

`stores/atoms/throttleWriteSessionAtom.ts` 里实现了一整套独立的 jotai atom + `WriteQueue`（`:23-66`），`flushInterval` 同样硬编码 `2000`ms（`:28`）——看起来是同一个"节流落盘"想法的另一份实现。全仓库 grep `createSessionAtom` 的结果（含原调查的单独复核）：

```
src/renderer/stores/atoms/throttleWriteSessionAtom.ts:8
src/renderer/stores/atoms/throttleWriteSessionAtom.ts:74
src/renderer/stores/atoms/throttleWriteSessionAtom.ts:82
src/renderer/stores/atoms/throttleWriteSessionAtom.ts:86
```

只有定义文件内部引用，**没有任何外部调用点**。同文件里的 `cleanupSessionAtomCache` 则确实被 `chatStore.ts:37,476` 引用（用于删除会话时清缓存）。也就是说这个模块里"创建/写入 atom"的那部分（`createSessionAtom`、`WriteQueue`）大概率是被废弃的旧实现，只有"清理"那半个函数还留在调用链里。

## 6. 完成、异常、半截流与最终回写

- 流结束/出错/暂停时无条件补一次 `persistStreamingMessage(..., { refreshCounting: true })`，确保最终态落盘（5.2）。
- **落盘时不丢失"正在生成"的消息（缓存合并保护）**：`mergeCachedGeneratingMessages`（`chatStore-cache.ts:26-52`）在磁盘上较旧的 session 快照写回缓存时，若某条消息在缓存里 `generating: true`，保留缓存里更新的内容。这是为了防止"用户改了会话名字触发的 metadata 更新"把正在流式输出的文本回退成更早的内容。数据语义与 UpdateQueue 在会话与消息管理笔记 6。
- 停止时：当前 `generating` 消息调用 `cancel()`，并把该消息以 `generating: false` 乐观写回（执行语义见第 7 节）。

## 7. 停止、重试、续写与重新生成

- **停止**：若当前存在 `generating` 消息，停止按钮调用其 `cancel()` 并把该消息以 `generating:false` 乐观写回（按钮状态与反馈见 Chat UI 笔记）。
- **重新生成/在新分支里重试**：`stores/session/generation.ts` 的 `regenerateInNewFork`/`generateMoreInNewFork` 产生新的 fork 分支（`position` 记录激活分支），分支数据语义见会话与消息管理笔记 1.3；执行链在本次调查中未逐行展开。
- **工具错误重试**：可恢复的工具错误会让用户选择重试整条消息或从最后工具步骤重试（入口见 Chat UI 笔记的消息操作）。
- **并发/队列**：本次调查范围内未发现独立的发送队列或后台任务管理器；多会话并发与同会话串行化的执行语义未验证。

## 8. 队列、多会话并发与后台生成

- 本次调查未覆盖独立的队列实现与后台生成机制；不虚构不存在的机制。多窗口并发写入的合并语义在会话与消息管理笔记 6 的 UpdateQueue 部分有部分覆盖。

## 9. Agent、工具、知识库与附件注入点

### 9.1 Copilot：本质是"系统提示词模板"，不是独立会话类型

`CopilotDetail`（`shared/types.ts:94-108`）：`{id, name, prompt, picUrl(deprecated), avatar, backgroundImage, description, tags, screenshots, createdAt, updatedAt, usedCount, sourceId, starred}`。选中一个 copilot 时（`routes/index.tsx:211-234`），行为是把 `session.copilotId` 设成该 id，并把 `session.messages[0]` 设成 `{ role: 'system', contentParts: [{type:'text', text: copilot.prompt}] }`——创建出来的仍然是一个普通 `type: 'chat'` 的 Session，只是多了一个 `copilotId` 字段用于用量统计（`remote.recordCopilotUsage`，在 create_session/create_thread/create_message 三个动作点调用）。

### 9.2 知识库：客户端只存 id/name 句柄，真正生效靠"工具"

前端状态只是 `Pick<KnowledgeBase, 'id'|'name'>`，没有把知识库内容拉到前端。真正生效的地方是生成阶段的 `buildToolsForSession`（`stores/session/tools-builder.ts:241-249`）：

```ts
const kbSupported = includeAgentTools && knowledgeBase && model.isSupportToolUse('knowledge-base')
...
if (knowledgeBase && kbSupported) {
  kbToolSet = await getKBToolSet(knowledgeBase.id, knowledgeBase.name)
}
```

即知识库是作为**一个模型可调用的工具**注册进去的（`getToolSet as getKBToolSet` 来自 `@/packages/model-calls/toolsets/knowledge-base`），依赖模型是否支持 `'knowledge-base'` 这个 `ToolUseScope`（`shared/types.ts:227`：`ToolUseScopeSchema = z.enum(['agent','web-browsing','knowledge-base','read-file'])`），而不是把知识库检索结果拼进 prompt 文本。

### 9.3 网页浏览：每会话布尔开关 + provider 默认值

生成时 `getSessionWebBrowsing(sessionId, provider)`（`stores/session/utils.ts`，从 `generation.ts:189` re-export）解析出布尔值，再在 `tools-builder.ts:299` 判断 `webBrowsing && model.isSupportToolUse('web-browsing')` 决定要不要注册 web-search 工具（`webSearchTool`/`parseLinkTool`，来自 `@/packages/model-calls/toolsets/web-search`）。同样是"工具开关"模式，不是"胶水 prompt"模式。界面上的默认值规则与按钮状态见 Chat UI 笔记。

### 9.4 三者收敛到同一条流水线

Agent 模式（`agent-mode.ts`）、知识库、网页浏览三个开关最终都汇入同一次调用——`orchestrateGeneration`（`orchestration.ts:577-600`）里的 `prepareAgentGenerationHarness`，内部统一走 `buildToolsForSession`。也就是说输入区这几个"上下文增强按钮"在架构上不是三套独立子系统，而是同一个工具注册管线里的三个布尔开关，每个开关各自受模型能力（`isSupportToolUse(scope)`）门控。

### 9.5 工具审批的暂停语义

`MAX_TOOL_CALLS_BEFORE_CONFIRMATION = 25`（`orchestration.ts:61`）：一次生成里，工具调用达到 25 次才会暂停要求用户确认，且暂停会冻结同一 step 里**整批**并行工具调用而不是单个——这条限制是在"普通 chat 模式"的 `orchestrateGeneration` 里实现的，但明显是 Agent 能力的一部分，说明 chat 与 agent 在实现上没有清晰边界，是本项目里"聊天"和"Agent"两个概念在代码层面交织最深的地方之一。审批的界面工作流见 Chat UI 笔记；工具执行循环内部语义属于 Agent 工具类目。

## 10. 退出恢复、日志与已确认边界

- 切换会话、关闭窗口、应用退出时的任务处理本次未调查。
- 已确认边界：源码直接确认的是 renderer 消息对象、历史选择和工具注册链；provider 最终 HTTP JSON 的字段顺序及各模型差异属于未核实事项。

## 11. 未验证事项

- provider 侧 token 截断策略与最终 payload 字段。
- `context-management` 包内的摘要/压缩触发细节。
- 停止的网络级取消效果、退出恢复与多会话并发行为需要运行验证。
- 工具循环内部的执行细节属于 Agent 工具类目，本笔记只记录注入点与审批暂停点。

## 12. 关键源码索引

- `src/renderer/components/InputBox/InputBox.tsx`（`handleSubmit`、输入收集）
- `src/renderer/stores/sessionHelpers.ts`（`constructUserMessage`）
- `src/renderer/stores/session/messages.ts`（`submitNewUserMessage`、`updateStreamingCache`/`persistStreamingMessage`、压缩触发点）
- `src/renderer/stores/session/orchestration.ts`（生成主循环、节流、tool-call 暂停）
- `src/renderer/stores/session/generation.ts`、`agent-harness.ts`、`utils.ts`（历史选择）
- `src/renderer/stores/session/tools-builder.ts`（知识库/网页浏览/agent 工具统一注册）
- `src/renderer/stores/session/agent-mode.ts`
- `src/renderer/stores/atoms/throttleWriteSessionAtom.ts`（疑似死代码）
- `src/renderer/stores/chatStore-cache.ts`（`mergeCachedGeneratingMessages`）
- `src/shared/types.ts`（`ToolUseScopeSchema` 等）
