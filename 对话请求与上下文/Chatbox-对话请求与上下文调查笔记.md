# Chatbox 对话请求与上下文调查笔记

> 调查对象：`E:\works\git\chatbox`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`81571269addb6bafb589a920b2883f1e1e084fd1`（分支：`main`）
>
> 调查方式：直接阅读源码（React 组件、renderer store、上下文构建与压缩包、模型调用层），符号与行号对照当前 HEAD 逐一核实，未运行应用
>
> 调查范围：一次生成任务的提交入口、上下文拼装、流式消费、节流落盘、停止与回写；会话数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Chatbox 的一次生成任务由输入区提交开始，最终落到 `orchestrateGeneration` 消费模型流式输出：

- **主链**：`InputBox.handleSubmit` → `constructUserMessage` → `submitNewUserMessage`（写用户消息 + 插入 assistant 占位）→ `orchestrateGeneration` → `model.chatStream()` 逐 chunk 消费。
- **流式更新拆成两条频率完全不同的路径**：每个 text-delta/reasoning-delta chunk 立刻刷新 UI 缓存（几乎逐 token），但只有"距上次落盘 ≥ 2 秒"或"chunk 是 tool-call"时才真正写 storage；流结束/出错/暂停时再无条件补一次最终落盘。
- **Agent 模式、知识库、网页浏览三种"输入区上下文增强"在底层统一建模成同一个工具注册管线里的三个开关**，而不是三套独立的 prompt 拼接逻辑，每个开关受模型能力（`isSupportToolUse(scope)`）门控。
- **同会话生成串行化**：`submitNewUserMessage`/`generate`/`generateMoreInNewFork` 等入口被每会话的生成锁（promise 尾链）串行化；"在下方继续回复"（`generateMore`）在 chat 会话刻意绕过锁以支持并行替代回复，其消息写入由 chatStore 的 UpdateQueue 串行兜底。
- 上下文按"消息数上限（`maxContextMessageCount`）"裁剪历史，自动压缩按 token 预算（上下文窗口 × 阈值 0.6）触发；provider 最终 payload 字段属于未核实事项。
- 停止时生成锁保持到流真正排空；未完成的 tool-call 批收口为 error/result 态（`cancelled: true`），空内容占位消息直接删除。

## 系统边界与生成任务主链

```text
InputBox.handleSubmit（收集文本/附件/开关状态）
  -> sessionHelpers.constructUserMessage（图片进 contentParts、文件进 files、链接进 links）
  -> routes/index.tsx 或 routes/session/$sessionId.tsx 的 onSubmit
  -> submitNewUserMessage（带生成锁：写用户消息 -> 插入 assistant 占位 -> 压缩检查 -> 进入生成）
  -> _generateWithoutSessionLock -> orchestrateGeneration（chat）或 orchestratePictureGeneration（picture）
      -> agent-harness.prepareAgentGenerationHarness（历史选择 + buildContext + buildToolsForSession）
      -> model.chatStream()（Provider 调用）
      -> 逐 chunk：updateStreamingCache（UI 缓存）或 persistStreamingMessage（落盘，2 秒节流 + tool-call 特例）
  -> 流结束/出错/暂停/中止 -> 无条件最终落盘
```

边界：会话与消息如何持久化、分支数据结构属于会话与消息管理；发送按钮、停止按钮、排队提示等用户可见状态属于 Chat UI；消息内容如何渲染属于消息渲染器。

## 1. 提交入口、任务对象与状态机

- `InputBox.tsx:837` 的 `handleSubmit`（`InputBox.tsx:837-946`）先做发送前校验（禁用态/模型存在/RAG 附件索引未就绪时弹"文档仍在索引中"确认，`:881-884`），再调 `sessionHelpers.constructUserMessage`（`sessionHelpers.ts:872-`）把图片、文件、链接分别归入消息的 `contentParts`/`files`/`links` 三组字段，然后经 `onSubmit?.(params)` 提交；`onUserMessageReady` 回调负责清草稿与输入历史（`:905-931`）。提交参数里的 `settingsPatch` 携带推理级别修改（`reasoningSettingsPatch`）。
- `stores/session/messages.ts:177` 的 `submitNewUserMessage` 用每会话生成锁包装（`withSessionGenerationLock`，`generation-lock.ts:8-26`）；内部 `submitNewUserMessageUnlocked`（`messages.ts:184-310`）先跑发送前压缩检查（`runCompactionWithUIState`，`:201`，见第 3 节），再插入用户消息与 assistant 占位（占位带 `generating: true`，附件/链接时分别带 `sending_file`/`loading_webpage` 状态，`:224-246`），最后 `_generateWithoutSessionLock`（`generation.ts:15-37`）按会话类型进入 chat 或 picture 生成。
- **任务对象就是目标消息本身**：没有独立的"任务记录"。生成状态落在消息字段上——`initializeTargetMessage`（`stores/session/utils.ts:129-148`）把占位消息置为 `generating: true` 并填入 provider/model/`isStreamingMode`；`orchestrateGeneration`（`orchestration.ts:480-514`）创建 `AbortController`，把 `cancel` 函数同时暴露到本地目标与权威缓存消息上（`exposeGenerationCancel`，`:466-478`），并登记/结算"会话生成中"计数（`beginSessionGeneration`/`settleSessionGeneration`，`generation-runtime.ts:13-35`）。
- 生成锁由 `withSessionGenerationLock`（`generation-lock.ts`）实现：每会话一条 promise 尾链，前一个任务完成后才执行下一个，任务失败不影响后续（`:3-7` 注释）。
- 首页"假会话"首次发送时会先走 `createPersistedChatSession` 创建真实 Session 再提交（数据语义见会话与消息管理笔记 3.1）。
- 停止时存在 `generating: true` 的消息调用其 `cancel()`；停止收口逻辑在 `stores/session/generation-cancellation.ts`（`stopGeneratingMessages`/`cancelRunningToolCallBatch`/`finishAbortedGeneration`，见第 7 节）。

## 2. 历史选择与上下文拼装顺序

`orchestrateGeneration` 内的 `runGeneration`（`orchestration.ts:516-977`）先经 `findTargetMessageIndex`（`utils.ts:107-113`）定位目标消息所在列表与下标（支持消息在归档 thread 中重试），再把 `messages.slice(0, targetMsgIx)`（`agent-harness.ts:206`）交给上下文构建：

1. 过滤不合格消息（`isContextEligibleMessage`：`shared/context/message-eligibility.ts:12`，排除 `generating` 与 `isForkMarker`）；
2. 应用压缩点（`shared/context/builder.ts:35-40, 58-100`，见第 3 节）；
3. 过滤错误消息（`filterErrorMessages`，`:157-159`）；
4. 按 `maxContextMessageCount` 消息数上限裁剪历史（`applyMessageLimit`，`:166-180`：上限只作用于历史，当前输入始终保留）；
5. 注入附件内容（`injectAttachments`，`:182-227`：内联文件 >500 行时只给前 100 行预览 + `<TRUNCATED>` 提示，`:364-383`；sandbox 模式只注入文件元数据；session-retrieval 附件注入检索占位与提醒，`:385-414`）。

**拼装顺序（最终请求）**：
1. `buildContext`（`agent-harness.ts:249-256`）构建基础上下文；
2. 无视觉模型时 OCR 预处理图片并追加 info part（`:260-279`）；
3. legacy 工具回退（`applyLegacyToolFallback`，`:281-287`）；
4. `buildToolsForSession` 注册工具（`:306-317`，见第 9 节）；
5. 注入模型级 system prompt（`injectModelSystemPrompt`，含工具 instructions 合并，`:321-326`）；
6. 不支持 system 消息的模型把 system 角色改写为 user（`:328-333`）；
7. `sequenceMessages` 排序（`:335`）；
8. `convertToModelMessages` 转换（`:337-`，含 DeepSeek reasoning 保留等模型差异）。

- **system prompt**：Copilot 的 `prompt` 在选中时写入 `session.messages[0]`（`{ role: 'system', contentParts: [...] }`），随历史一起进入请求（数据语义见会话与消息管理笔记 8）。
- **附件**保留在用户消息的 parts/files 字段中，随消息模型进入请求（第 2 步注入内容）。
- **知识库、网页浏览、Agent 模式**不拼进 prompt 文本，而是作为工具注册进本次请求（见第 9 节）。
- 压缩点按目标消息所在位置选择：`getCompactionPointsForTarget`（`utils.ts:121-124`）在归档 thread 内重试时取 thread 自己的压缩点，否则取 session 的。

## 3. 预算、截断、摘要与压缩

- **消息数上限**：`settings.maxContextMessageCount` 在 `buildContext` 中生效（`agent-harness.ts:253` → `builder.ts:44-46`），按"历史消息数 + 1 条当前输入"裁剪，不是 token 预算。
- **自动压缩触发**（发送前同步检查，阻塞发送）：`messages.ts:201` 的 `runCompactionWithUIState` → `compaction.ts` 的 `needsCompaction`（`:57-125`）用 token 估算（带 react-query 缓存，`context-tokens.ts`）调 `checkOverflow`（`compaction-detector.ts:31-58`），判定为 `isOverflow = tokens > max(contextWindow - 32000, contextWindow*0.5) * compactionThreshold`，`compactionThreshold` 默认 0.6、可全局设置；模型上下文窗口来自 provider 设置或模型注册表（`getModelContextWindowFromSettings`/`getModelContextWindowSync`），未知模型不触发。
- **执行与提交**：`runCompactionWithStreaming`（`compaction.ts:167-263`）流式生成摘要（UI 态经 `setCompactionUIState`），摘要消息打 `isSummary: true`；boundary 取"最后一个通过上下文合格性过滤且非 summary 的消息"（`compaction-boundary.ts:12-21`），生成 `CompactionPoint` 后经 `buildCompactionCommitPatch`（`compaction-commit.ts:28`）原子提交；摘要流式期间 boundary 被删除则放弃提交（`:240-247`）。压缩契约 `compactionPoints` 随 fork/复制重映射（数据语义见会话与消息管理笔记 1.4）。
- **压缩可逆**：删除摘要消息（UI 上 SummaryMessage 的"删除摘要"操作）即恢复原文参与上下文计算，`compactionPoints` 中对应点随之清理（`chatStore.ts:803-816`）。
- provider 侧 token 截断策略未在本次入口范围内完全核实（`packages/model-calls` 适配层职责）。

## 4. SDK、Provider、模型与协议交接

- 模型实例在生成主链内创建：`createModel(settings, dependencies)`（`orchestration.ts:623`），推理级别等参数按"provider+model"作用域解析（`resolveReasoningProviderOptions`，`:626`，注释明确防止切换模型后继承另一模型的参数）。
- 流式主循环消费 `model.chatStream(coreMessages, chatOptions)` 产出的每个 chunk（`orchestration.ts:755, 788-852`），`coreMessages` 是第 2 节拼装后的模型消息数组。
- 大图片/大工具结果经 `onFileReceived`/`onLargeToolResult` 写 blob storage 后以 storageKey 入消息（`:761-772`）。
- 具体各 provider payload 字段由 `packages/model-calls` 的 API 适配层生成，本笔记未逐一展开；`chat` 与 `picture` 两类会话对应不同模型集合（`lastUsedModelStore` 分字段记录）。

## 5. 流式事件、缓冲、节流与顺序

### 5.1 两条完全独立的写路径

`stores/session/messages.ts`：

- `updateStreamingCache(sessionId, message)`（`:132-137`）：只调 `chatStore.updateMessageCache`（`chatStore.ts:414-433`）经内部缓存函数直接改 react-query 缓存（`queryClient.setQueryData`），**不碰 storage**，注释里写明"性能优先，不检查 session 存在性"。
- `persistStreamingMessage(sessionId, message, options)`（`:143-155`）：调 `chatStore.updateMessage`（`updateSessionWithMessages`，`chatStore.ts:351-392`），走每会话一个的 `UpdateQueue`（`stores/updateQueue.ts`，基于 `queueMicrotask` 的串行合并队列，避免并发 update 互相覆盖），**真正写 storage**。

### 5.2 节流策略：2 秒定时 + 特例立即持久化

节流判断函数 `shouldPersistStreamingChunk`（`stores/session/orchestration.ts:455-464`）：

```ts
export function shouldPersistStreamingChunk(chunkType, elapsedMs, persistInterval) {
  // Tool calls can block the stream for a long time (for example while waiting
  // on user_exec approval), so persist them immediately instead of relying on
  // the periodic 2s flush.
  return chunkType === 'tool-call' || elapsedMs >= persistInterval
}
```

`persistInterval` 硬编码 `2000`（`orchestration.ts:566`）。主循环（`orchestration.ts:788-852`）里：

```ts
const shouldPersist = shouldPersistStreamingChunk(
  chunk.type,
  Date.now() - lastPersistTimestamp,
  persistInterval
)
if (shouldPersist) {
  void persistStreamingMessage(sessionId, targetMsg)   // 落盘（异步、不等待）
} else {
  updateStreamingCache(sessionId, targetMsg)            // 只刷 UI
}
```

也就是：**每个 text-delta/reasoning-delta chunk 都会立刻刷新 UI 缓存**（几乎逐 token），但只有"距上次落盘 ≥ 2 秒"或"这个 chunk 是 tool-call"时才真正写 storage。流结束/出错/暂停/中止时还各自补一次无条件的 `persistStreamingMessage(..., { refreshCounting: true })`（调用点 `:543, 575, 605, 617, 673, 706, 907, 942, 963, 973`），确保最终态一定落盘。

`tool-call` 被特殊处理的原因写在注释里：tool-call 可能长时间阻塞在等用户批准（`user_exec_approval`/`file_mutation_approval`/`app_action_approval`），如果不立刻持久化，用户刷新/关闭应用会丢失这个待批准状态。

**停止路径的流排空处理**：主循环把 chunk 读取与 abort 信号做 `Promise.race`（`orchestration.ts:788-801`），abort 后立即收口消息（不再等待仍在执行的工具 step 返回）；生成锁保持到流真正排空（`streamIterator.return()` 的 drain，`:867-893`，并注册 `registerUnsettledStreamDrain` 供后续生成入口等待），避免"停止后又冒出半个 chunk"。停止时未完成 tool-call 由 `generation-cancellation.ts` 收口（见第 7 节）。

### 5.3 一处疑似死代码：`throttleWriteSessionAtom.ts`

`stores/atoms/throttleWriteSessionAtom.ts` 是疑似死代码：它实现了一整套独立的 jotai atom + `WriteQueue`（`:23-66`），`flushInterval` 同样硬编码 `2000`ms（`:28`），看起来是同一个"节流落盘"想法的另一份实现。但全仓库 grep `createSessionAtom` 的结果只有定义文件内部引用（`:74, 79, 86, 89, 90`，导出经 `stores/atoms/index.ts:4` 的 `export *` 透传），**没有任何外部调用点**。同文件里的 `cleanupSessionAtomCache` 则确实被 `chatStore.ts:37, 477` 引用（用于删除会话时清缓存）。也就是说该模块"创建/写入 atom"的那部分（`createSessionAtom`、`WriteQueue`）是未被调用的旧实现，只有"清理"那半个函数还留在调用链里。

## 6. 完成、异常、半截流与最终回写

- **成功收口**（`orchestration.ts:930-946`）：置 `generating: false`、清除 `cancel`，写回 `finishReason`/`usage`/`generationDuration`，并无条件 `persistStreamingMessage(..., { refreshCounting: true })`；首次成功会话另有完成标记（`markFirstSuccessfulChatCompleted`，`:943-945`）。
- **tool-call 暂停收口**（`:896-909` 与 catch 分支 `:947-965`）：存在 `state === 'paused'` 的 tool-call part 或捕获到暂停错误时，消息以 `finishReason: 'tool-call-paused'` 落盘（`markToolCallPaused`），保留已执行部分的 contentParts。
- **中止收口**（`:867-894`）：`persistAbortedGenerationIfNeeded` → `finishAbortedGeneration`（`generation-cancellation.ts:54-82`），`finishReason: 'canceled'`。
- **错误收口**：`handleGenerationError`（`utils.ts:153-227`）把 `errorCode/error/errorExtra`（含 OCR 提供商、HTTP 状态码、requestId 等）写回消息并落盘（`orchestration.ts:969-975`）。
- **落盘时不丢失"正在生成"的消息（缓存合并保护）**：`mergeCachedGeneratingMessages`（`chatStore-cache.ts:26-79`）在磁盘上较旧的 session 快照写回缓存时，若某条消息在缓存里 `generating: true`，保留缓存里更新的内容，防止"用户改了会话名字触发的 metadata 更新"把正在流式输出的文本回退成更早的内容（合并覆盖的层级与数据语义见会话与消息管理笔记 6）。

## 7. 停止、重试、续写与重新生成

- **停止**（数据侧）：`stopGeneratingMessages`（`generation-cancellation.ts:84-101`）逐个调 `message.cancel()`，然后对每个消息分类收口：
  - `contentParts` 为空（还没产出任何内容的占位）→ `removeMessage` 直接删除；
  - 非空 → `finishAbortedGeneration` 收口（`cancelRunningToolCallBatch`，`:21-51`）。工具批收口规则：`user_exec`/`code_execution` 收口为 `result`（`exitCode: 130, cancelled: true`），其余工具收口为 `error`（`cancelled: true`），reasoning part 补 duration，最后 `persistMessage` 落盘。
  界面入口（停止按钮、消息内停止）见 Chat UI 笔记。
- **重新生成/在新分支里重试**：`regenerateInNewFork`（`generation.ts:104-139`）在目标消息的上一条非 summary 消息处创建新 fork（`createNewFork`）后重新生成；fork pivot 会跳过锚定压缩摘要（`:123-130`）。`generateMoreInNewFork`（`:95-100`）先 `createNewFork` 再在分叉点下方续写。分支数据语义见会话与消息管理笔记 1.3。
- **在下方继续回复**：`generateMore`（`generation.ts:80-93`）：picture 会话走生成锁串行，chat 会话刻意绕过锁、经 `createInactiveFork` 保存当前分支后以"替代回复"并行生成（`:63-78` 注释：消息写入由 chatStore UpdateQueue 串行化兜底）。
- **工具错误重试**：`retryFromLastToolCallAfterApiError`（`orchestration.ts:1399-`）从最后可重试工具步骤继续；UI 上用户可选择重试整条消息或从最后工具步骤重试（入口见 Chat UI 笔记的消息操作）。
- **暂停后继续**：`continuePausedToolCall`（`orchestration.ts:1157-`）与 `disableToolCallLimitPauseAndContinue`（`:1170-`，"继续并本次不再暂停确认"，把暂停的 tool-call 批恢复执行）。

## 8. 队列、多会话并发与后台生成

- **同会话串行化**：`submitNewUserMessage`/`generate`/`generateMoreInNewFork`/`regenerateInNewFork` 都走每会话 promise 尾链（`withSessionGenerationLock`，`generation-lock.ts:8-26`）；替代回复（`generateMore` chat 分支）故意绕过锁并行运行，写入由 `UpdateQueue` 串行合并（`chatStore.ts:349-392`）。
- **多会话并行**：锁是 per-session 的，不同会话的生成互不阻塞；本次未发现全局发送队列或后台任务管理器——多会话并发与后台生成没有独立的调度层，都是直接发起的生成任务。
- **流排空等待**：新生成在启动前会等待同会话未结算的 stream drain（`orchestration.ts:594-608`，可被自己的停止按钮中止等待），保证前一次停止的工具残留不会与新生成交错。
- 多窗口并发写入的合并语义在会话与消息管理笔记 6 的 UpdateQueue 部分有部分覆盖。

## 9. Agent、工具、知识库与附件注入点

### 9.1 Copilot：本质是"系统提示词模板"，不是独立会话类型

`CopilotDetail`（`src/shared/types.ts:94-110`）的字段如下（`picUrl` 已标记 deprecated）：

```ts
{ id, name, prompt, picUrl(deprecated), avatar, backgroundImage, description,
  tags, screenshots, createdAt, updatedAt, usedCount, sourceId, starred }
```

选中一个 copilot 时（`routes/index.tsx:211-234`），行为是把 `session.copilotId` 设成该 id，并把 `session.messages[0]` 设成 `{ role: 'system', contentParts: [{type:'text', text: copilot.prompt}] }`——创建出来的仍然是一个普通 `type: 'chat'` 的 Session，只是多了一个 `copilotId` 字段用于用量统计（`remote.recordCopilotUsage`，`routes/index.tsx:302-306`）。

### 9.2 知识库：客户端只存 id/name 句柄，真正生效靠"工具"

前端状态只是 `Pick<KnowledgeBase, 'id'|'name'>`，没有把知识库内容拉到前端。真正生效的地方是生成阶段的 `buildToolsForSession`（`stores/session/tools-builder.ts:241, 246-253`），判定逻辑见下方代码块：

```ts
const kbSupported = Boolean(knowledgeBase) && model.isSupportToolUse('knowledge-base')
...
if (knowledgeBase && kbSupported) {
  kbToolSet = await getKBToolSet(knowledgeBase.id, knowledgeBase.name)
}
```

即知识库是作为**一个模型可调用的工具**注册进去的（`getToolSet as getKBToolSet` 来自 `@/packages/model-calls/toolsets/knowledge-base`），依赖模型是否支持 `'knowledge-base'` 这个 `ToolUseScope`（`src/shared/types/session.ts:227`：`ToolUseScopeSchema = z.enum(['agent','web-browsing','knowledge-base','read-file'])`），而不是把知识库检索结果拼进 prompt 文本。

### 9.3 网页浏览：每会话布尔开关 + provider 默认值

生成时 `getSessionWebBrowsing(sessionId, provider)`（`stores/session/utils.ts:33-40`；显式设置优先，否则 ChatboxAI 默认开、其他 provider 默认关）解析出布尔开关，再在 `tools-builder.ts:242, 299-306` 判断该开关与模型是否支持 `'web-browsing'`，都满足才注册 `web_search` 工具，并按所选搜索 provider 的能力决定是否附加 `parse_link`（`:244, 303-305`）。同样是"工具开关"模式，不是"胶水 prompt"模式。界面上的默认值规则与按钮状态见 Chat UI 笔记。

### 9.4 三者收敛到同一条流水线

Agent 模式（`agent-mode.ts`，`agentModeValue` 经 `computeEffectiveAgentMode` 结合平台/模型能力收敛，`agent-harness.ts:215`）、知识库、网页浏览三个开关最终都汇入同一次调用——`orchestrateGeneration`（`orchestration.ts:713`）里的 `prepareAgentGenerationHarness`，内部统一走 `buildToolsForSession`（`agent-harness.ts:306-317`）。工具注册顺序（`tools-builder.ts:291-365`）：

- MCP（仅 agent 模式）；
- `web_search`/`parse_link`（独立于 agent 模式）；
- 知识库；
- session-attachment RAG；
- 文件读取；
- code_execution；
- 文件系统；
- skills/`user_exec`/`install_skill`（仅 agent 模式）。

也就是说输入区这几个"上下文增强按钮"在架构上是同一个工具注册管线里的布尔开关，每个开关各自受模型能力（`isSupportToolUse(scope)`）门控。

### 9.5 工具审批的暂停语义

`MAX_TOOL_CALLS_BEFORE_CONFIRMATION = 25`（`shared/utils/tool-call-limit-pause.ts:7`）：一次生成里，工具调用达到 25 次才会暂停要求用户确认，且暂停会冻结同一 step 里**整批**并行工具调用而不是单个——这条限制是在"普通 chat 模式"的 `orchestrateGeneration` 里实现的（`withToolCallLimitPause` 包装，`orchestration.ts:750-752`），说明 chat 与 agent 在实现上没有清晰边界，是本项目里"聊天"和"Agent"两个概念在代码层面交织最深的地方之一。

`pauseOnToolCallLimit` 设置可**按会话覆盖或全局关闭**该确认点（`shouldPauseOnToolCallLimit`，`tool-call-limit-pause.ts:14-19`；会话字段 `SessionSettings.pauseOnToolCallLimit`，全局 `Settings.pauseOnToolCallLimit` 默认 true）；关闭时工具不再被该包装。继续按钮拆分为"继续/继续并本次不再暂停确认"（`disableToolCallLimitPauseAndContinue`，`orchestration.ts:1170-`）。暂停类审批（user_exec/file_mutation/app_action）不受该开关影响，暂停状态随消息以 `finishReason: 'tool-call-paused'` 落盘（第 6 节）。审批的界面工作流见 Chat UI 笔记；工具执行循环内部语义属于 Agent 工具类目。

### 9.6 Agent 模式建议（本次新增核实）

`agentMode` 为 `auto` 且是首轮用户消息时，`orchestrateGeneration` 会在正式生成前用"分类器模型"判断是否建议开启 Agent 模式（`orchestration.ts:636-711`）：建议时目标消息以 `agent-mode-suggestion` part + `finishReason: 'agent-mode-suggested'` 收口落盘，不进入模型生成；接受/拒绝由 UI 决定（`Message.tsx` 的建议卡）。分类器模型可独立于会话模型（`threadNamingModel`），参数解析按实际运行模型作用域处理（`:648-659`）。

## 10. 退出恢复、日志与已确认边界

- 切换会话、关闭窗口、应用退出时的任务处理本次未调查（无专门的"后台任务管理器"代码路径，见第 8 节）。
- 可观测性：`trackGenerateEvent`（`utils.ts:46-100`）在发送关键路径采集 provider/model/操作类型/开关状态等事件（含 MCP/技能/工作目录计数，带 bucket），要求永不抛错（`:42-45` 注释）；错误上送 Sentry（`handleGenerationError`，`utils.ts:160-182`）。
- 已确认边界：源码直接确认的是 renderer 消息对象、历史选择和工具注册链；provider 最终 HTTP JSON 的字段顺序及各模型差异属于未核实事项（`packages/model-calls` 适配层）。

## 11. 未验证事项

- provider 侧 token 截断策略与最终 payload 字段。
- 停止的网络级取消效果、退出恢复与多会话并发行为需要运行验证（静态代码确认了 abort 信号链路与生成锁，实际取消延迟取决于各 provider SDK 与工具实现）。
- 压缩的触发频率与摘要质量、长上下文下的实际行为需要运行验证（阈值公式已核实，见第 3 节）。
- 工具循环内部的执行细节属于 Agent 工具类目，本笔记只记录注入点与审批暂停点。
- 附件侧（预处理失败上浮为消息错误、RAG 索引未就绪的发送确认）的完整失败恢复工作流未运行验证。

## 12. 关键源码索引

- `src/renderer/components/InputBox/InputBox.tsx`（`handleSubmit`、输入收集）
- `src/renderer/stores/sessionHelpers.ts`（`constructUserMessage`）
- `src/renderer/stores/session/messages.ts`（`submitNewUserMessage`、`updateStreamingCache`/`persistStreamingMessage`、压缩触发点）
- `src/renderer/stores/session/orchestration.ts`（生成主循环、节流、tool-call 暂停、agent 模式建议）
- `src/renderer/stores/session/generation.ts`、`agent-harness.ts`、`utils.ts`（历史选择与上下文构建）
- `src/renderer/stores/session/tools-builder.ts`（知识库/网页浏览/agent 工具统一注册）
- `src/renderer/stores/session/generation-cancellation.ts`、`generation-lock.ts`、`generation-runtime.ts`
- `src/renderer/stores/atoms/throttleWriteSessionAtom.ts`（疑似死代码）
- `src/renderer/stores/chatStore-cache.ts`（`mergeCachedGeneratingMessages`）
- `src/shared/context/builder.ts`、`compaction-points.ts`
- `src/renderer/packages/context-management/`（`compaction-detector.ts`、`compaction.ts`、`compaction-boundary.ts`、`compaction-commit.ts`）
- `src/shared/types/session.ts`（`ToolUseScopeSchema` 等）、`src/shared/utils/tool-call-limit-pause.ts`
