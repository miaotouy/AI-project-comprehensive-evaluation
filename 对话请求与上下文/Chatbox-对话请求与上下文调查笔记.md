# Chatbox 对话请求与上下文调查笔记

> 调查对象：`https://github.com/chatboxai/chatbox`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`d17455c5ca8fd3ff44385c6d4d2118599e4c970f`（分支：`main`）
>
> 调查方式：直接阅读源码（React 组件、renderer store、上下文构建与压缩包、模型调用层），符号与行号对照当前 HEAD 逐一核实，未运行应用
>
> 调查范围：一次生成任务的提交入口、上下文拼装、流式消费、节流落盘、停止与回写；会话数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Chatbox 的一次生成任务由输入区提交开始，最终落到 `orchestrateGeneration` 消费模型流式输出：

- **主链**：`InputBox.handleSubmit` → `constructUserMessage` → `submitNewUserMessage`（写用户消息 + 插入 assistant 占位）→ `orchestrateGeneration` → `model.chatStream()` 逐 chunk 消费。
- **流式更新拆成两条频率不同的路径**：每个 text-delta/reasoning-delta chunk 立刻刷新 UI 缓存（几乎逐 token），但只有"距上次落盘 ≥ 2 秒"或"chunk 是 tool-call"时才真正写 storage；流结束/出错/暂停时再无条件补一次最终落盘。
- **Agent 模式、知识库、网页浏览三种"输入区上下文增强"共用同一个工具注册管线**，各自是管线里的一个开关，受模型能力（`isSupportToolUse(scope)`）门控。
- **模式决定并发语义**：Chat Mode 在生成中继续保留停止控件，不接受新排队消息；Work Mode 可把生成中的新输入写入每会话队列，用户还可显式让纯文本队列项作为 steering 消息插入当前生成。替代回复仍可并行，只有一个生成实例能取得该会话的 steering 消费权。
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

- 用户在输入区提交时，入口先根据禁用态、模型存在性与会话锁等条件判断动作；命中阻断就直接返回，会话锁可另行提示。通过后，只有未就绪且未被 blocked 的 session-retrieval 附件会触发“文档仍在索引中”确认（`InputBox.tsx:922-991`）。

  校验通过后调用 `constructUserMessage`（`sessionHelpers.ts:872-`），把图片、文件、链接分别归入消息的 contentParts、files 与 links 字段，再经路由层提交。提交完成回调负责清空草稿与输入历史；提交参数额外携带推理级别修改。
- 提交动作由 `submitNewUserMessage`（`messages.ts:177-310`）接管，内部由会话级生成锁串行执行（`generation-lock.ts:8-26`）。进入锁后：先跑一次发送前压缩检查（见第 3 节），再插入用户消息和带生成中标记的 assistant 占位——附件与链接场景下占位消息分别带 `sending_file / loading_webpage` 状态，最后按会话类型进入 chat 或 picture 生成（`generation.ts:15-37`）。
- **任务对象就是目标消息本身**，没有独立的“任务记录”，生成状态直接落在消息字段上。占位消息由 `stores/session/utils.ts:129-148` 置为 `generating: true` 并填入 provider、model 与流式模式标记；`orchestration.ts:466-514` 随后创建 `AbortController`，把取消函数同时挂到本地目标消息与缓存中的权威消息上，并登记、结算“会话生成中”计数（`generation-runtime.ts:13-35`）。
- 生成锁由 `withSessionGenerationLock` 实现：每会话维护一条 promise 尾链，前一个任务完成后才轮到下一个，某个任务失败也不影响后续（`generation-lock.ts:3-7`）。
- 首页"假会话"首次发送时会先走 `createPersistedChatSession` 创建真实 Session 再提交（数据语义见会话与消息管理笔记 3.1）。
- 停止时存在 `generating: true` 的消息调用其 `cancel()`；停止收口逻辑在 `stores/session/generation-cancellation.ts`（`stopGeneratingMessages`/`cancelRunningToolCallBatch`/`finishAbortedGeneration`，见第 7 节）。

## 2. 历史选择与上下文拼装顺序

`runGeneration`（`orchestration.ts:516-977`）先用定位函数找到目标消息所在的列表与下标（`utils.ts:107-113`），这一步支持消息在归档 thread 中重试；随后把目标消息之前的历史切片 `messages.slice(0, targetMsgIx)` 交给上下文构建，切片点见 `agent-harness.ts:206`：

1. 过滤不合格消息：仍在生成的消息与 fork 标记消息直接排除（`shared/context/message-eligibility.ts:12`）；
2. 应用压缩点（见第 3 节）；
3. 过滤出错的消息；
4. 按消息数上限裁剪历史，上限只作用于历史，当前输入始终保留；
5. 注入附件内容：内联文件超过 500 行时只给前 100 行预览并附 `<TRUNCATED>` 截断提示，sandbox 模式只注入文件元数据，session-retrieval 附件注入检索占位与提醒。

第 2 至 5 步的实现集中在 `src/shared/context/builder.ts:35-414`。

**拼装顺序（最终请求）**：
1. `buildContext` 构建基础上下文；
2. 模型不支持视觉输入时，先对图片做 OCR 预处理，把识别结果作为 info part 追加；
3. 应用 legacy 工具回退；
4. `buildToolsForSession` 注册本次可用的工具（见第 9 节）；
5. 注入模型级 system prompt，并把工具 instructions 合并进去；
6. 不支持 system 消息的模型，把 system 角色改写为 user；
7. `sequenceMessages` 对消息排序；
8. `convertToModelMessages` 做模型消息转换，其间处理 DeepSeek reasoning 保留等模型差异。

八个步骤都在 `src/renderer/stores/session/agent-harness.ts:249-337` 内完成。

- **system prompt**：Copilot 的 `prompt` 在选中时写入 `session.messages[0]`（`{ role: 'system', contentParts: [...] }`），随历史一起进入请求（数据语义见会话与消息管理笔记 8）。
- **附件**保留在用户消息的 parts/files 字段中，随消息模型进入请求（第 2 步注入内容）。
- **知识库、网页浏览、Agent 模式**不拼进 prompt 文本，而是作为工具注册进本次请求（见第 9 节）。
- 压缩点按目标消息所在位置选择：`getCompactionPointsForTarget`（`utils.ts:121-124`）在归档 thread 内重试时取 thread 自己的压缩点，否则取 session 的。

## 3. 预算、截断、摘要与压缩

- **消息数上限**：会话设置里的 `maxContextMessageCount` 只按条数裁剪历史，裁剪量取"历史消息数 + 1 条当前输入"，与实际 token 量无关。该上限在 `buildContext` 内应用，定位见 `agent-harness.ts:253` 与 `builder.ts:44-46`。
- **自动压缩触发**（发送前同步检查，阻塞发送）：判定入口在 `compaction.ts:57-125`，它先估算当前上下文的 token 用量（结果带 react-query 缓存，见 `context-tokens.ts`），再与预算比较（溢出判定见 `compaction-detector.ts:31-58`），溢出条件为 `isOverflow = tokens > max(contextWindow - 32000, contextWindow*0.5) * compactionThreshold`。阈值默认 0.6、可全局调整；上下文窗口取自 provider 设置或模型注册表，未知模型不触发压缩。检查由 `messages.ts:201` 的发送前压缩流程发起。
- **执行与提交**：摘要由 `compaction.ts:167-263` 流式生成，UI 展示进度，摘要消息标记 `isSummary: true`。boundary 取"最后一个通过上下文合格性过滤、且本身不是摘要的消息"（`compaction-boundary.ts:12-21`），据此生成压缩点，再由 `compaction-commit.ts:28` 原子提交；摘要流式期间若该 boundary 消息被删除，则放弃提交。压缩点 `compactionPoints` 随 fork 与复制重映射（数据语义见会话与消息管理笔记 1.4）。
- **自定义摘要指令**：全局 `compactionPrompt` 可在聊天设置或手动压缩弹窗编辑；执行服务优先使用本次显式 prompt，其次使用全局配置，再回退本地化默认提示。`packages/chatbox-core/src/application/context/CompactionService.ts:158`、`src/renderer/routes/settings/chat.tsx:579-586`。
- **压缩可逆**：删除摘要消息（UI 上 SummaryMessage 的"删除摘要"操作）即恢复原文参与上下文计算，`compactionPoints` 中对应点随之清理（压缩提交与压缩点维护在 `@chatbox/core` 的 `SessionService`）。
- provider 侧 token 截断策略未在本次入口范围内完全核实（`packages/model-calls` 适配层职责）。

## 4. SDK、Provider、模型与协议交接

- 模型实例在生成主链内创建：`createModel(settings, dependencies)` 之后，推理级别等参数按"provider+model"作用域单独解析（`resolveReasoningProviderOptions`），注释写明这样可避免切换模型后继承另一个模型的参数。定位见 `orchestration.ts:623-626`。
- 流式主循环逐个消费 `model.chatStream(coreMessages, chatOptions)` 产出的 chunk（`orchestration.ts:755-852`），其中的 `coreMessages` 是第 2 节拼装完成的模型消息数组。
- 大图片与超大工具结果先经 `onFileReceived`/`onLargeToolResult` 写入 blob storage，再以 storageKey 的形式进入消息（`orchestration.ts:761-772`）。
- 具体各 provider payload 字段由 `packages/model-calls` 的 API 适配层生成，本笔记未逐一展开；`chat` 与 `picture` 两类会话对应不同模型集合（`lastUsedModelStore` 分字段记录）。

## 5. 流式事件、缓冲、节流与顺序

### 5.1 两条完全独立的写路径

`stores/session/messages.ts`：

- `updateStreamingCache(sessionId, message)`（`messages.ts:132-137`）只改 react-query 缓存：它经 `SessionQueryBridge.updateMessageCache` 直接调用 `queryClient.setQueryData`，不写 storage；注释说明这里以性能优先，因此不检查会话是否存在。
- `persistStreamingMessage(sessionId, message, options)`（`messages.ts:143-155`）负责真正写 storage：它调用 `updateMessage` 经 `RowBackedSessionRepository` 提交行存储，并经过每会话一个的 `UpdateQueue`（`stores/updateQueue.ts`，基于 `queueMicrotask` 的串行合并队列）排队，避免并发更新互相覆盖。

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

每个 text-delta/reasoning-delta chunk 都会立刻刷新 UI 缓存（几乎逐 token），但只有"距上次落盘 ≥ 2 秒"或"这个 chunk 是 tool-call"时才真正写 storage。流结束/出错/暂停/中止时还各自补一次无条件的 `persistStreamingMessage(..., { refreshCounting: true })`（调用点 `:543, 575, 605, 617, 673, 706, 907, 942, 963, 973`）。

`tool-call` 被特殊处理的原因写在注释里：tool-call 可能长时间阻塞在等用户批准（`user_exec_approval`/`file_mutation_approval`/`app_action_approval`），如果不立刻持久化，用户刷新/关闭应用会丢失这个待批准状态。

**停止路径的流排空处理**：主循环把 chunk 读取与 abort 信号做 `Promise.race`（`orchestration.ts:788-801`），abort 后立即收口消息（不再等待仍在执行的工具 step 返回）；生成锁保持到流真正排空（`streamIterator.return()` 的 drain，`:867-893`，并注册 `registerUnsettledStreamDrain` 供后续生成入口等待），避免"停止后又冒出半个 chunk"。停止时未完成 tool-call 由 `generation-cancellation.ts` 收口（见第 7 节）。

### 5.3 节流写入的单一实现

节流写入只有一条实现路径：`persistStreamingMessage`（`messages.ts:143-155`）配合每会话一个的串行更新队列（`stores/updateQueue.ts`），flush interval 固定为 2000ms。该模块里"创建/写入 atom"的部分已脱离调用链：全仓库搜索 `createSessionAtom` 只命中定义文件自身的第 74-90 行（导出经 atoms 索引透传），运行时没有任何外部调用点；仍在用的只有"清理"这一半，删除会话时由 `chatStore.ts:37, 477` 调用清缓存。因此创建/写入这一半与对应的 WriteQueue 属于未被调用的旧实现。

## 6. 完成、异常、半截流与最终回写

- **成功收口**（`orchestration.ts:930-946`）：把消息的 `generating` 置回 false 并清除 `cancel`。随后写回 `finishReason / usage / generationDuration` 三个字段，并做一次无条件落盘（带 `refreshCounting: true`）确保写入；首次成功完成的会话还会打上首次成功完成标记。
- **tool-call 暂停收口**（`orchestration.ts:896-965`）：消息里存在 `state === 'paused'` 的 tool-call part，或 catch 分支捕获到暂停错误时，消息以 `finishReason: 'tool-call-paused'` 落盘（`markToolCallPaused`），已执行部分产生的 contentParts 予以保留。
- **中止收口**（`orchestration.ts:867-894`）：经由 `persistAbortedGenerationIfNeeded` 与 `finishAbortedGeneration`（`generation-cancellation.ts:54-82`）收口，消息最终带 `finishReason: 'canceled'`。
- **错误收口**：`handleGenerationError`（`utils.ts:153-227`）把 `errorCode/error/errorExtra`（含 OCR 提供商、HTTP 状态码、requestId 等）写回消息并落盘（`orchestration.ts:969-975`）。
- **落盘时不丢失"正在生成"的消息（缓存合并保护）**：磁盘上较旧的 session 快照写回缓存时，`mergeCachedGeneratingMessages`（`src/renderer/stores/session/:26-79`）逐条比对，某条消息在缓存里仍是 `generating: true` 就保留缓存中较新的内容，避免"用户改了会话名字触发的 metadata 更新"把正在流式输出的文本回退成更早的版本（合并覆盖的层级与数据语义见会话与消息管理笔记 6）。

## 7. 停止、重试、续写与重新生成

- **停止**（数据侧）：`stopGeneratingMessages`（`generation-cancellation.ts:84-101`）先逐个调用待停止消息的 `cancel()`，再按消息内容分两类收口：
  - `contentParts` 为空（还没产出任何内容的占位）→ 用 `removeMessage` 直接删除；
  - 内容非空 → 走中止收口，其中未完成的工具批由批取消函数处理（`generation-cancellation.ts:21-101`）。`user_exec / code_execution` 收口为 `result` 状态（退出码 130、`cancelled: true`），其余工具收口为 `error` 状态（带同样的取消标记），reasoning part 补上耗时，最后落盘。
  界面入口（停止按钮、消息内停止）见 Chat UI 笔记。
- **重新生成/在新分支里重试**：`regenerateInNewFork` 在目标消息之前最近的一条非摘要消息处创建新 fork 并重新生成，fork 的切点会跳过锚定的压缩摘要；`generateMoreInNewFork` 则先建 fork，再在分叉点下方续写。两个入口都在 `generation.ts:95-139` 内。分支数据语义见会话与消息管理笔记 1.3。
- **在下方继续回复**：`generateMore` 在 picture 会话里走生成锁串行执行；chat 会话刻意绕过锁，先经 `createInactiveFork` 保存当前分支，再以"替代回复"并行生成，消息写入由每会话的 UpdateQueue 串行化兜底（`generation.ts:63-93`）。
- **工具错误重试**：`retryFromLastToolCallAfterApiError`（`orchestration.ts:1399-`）从最后可重试工具步骤继续；UI 上用户可选择重试整条消息或从最后工具步骤重试（入口见 Chat UI 笔记的消息操作）。
- **暂停后继续**：`continuePausedToolCall` 与 `disableToolCallLimitPauseAndContinue` 都用于把暂停的 tool-call 批恢复执行，后者对应界面上的"继续并本次不再暂停确认"（`orchestration.ts:1157-`）。

## 8. 队列、多会话并发与后台生成

- **Work Mode 队列**：生成中提交的新输入最多排 20 条，队列状态写入 `localStorage['chatbox-message-queue-state']`；入队写盘失败时撤销本次入队并保留草稿。当前生成正常结束后，队列按顺序继续发送；停止、出错、模式建议或会话分支变化都会让队列暂停，用户可编辑、删除、清空或手动继续。实现见 `src/renderer/stores/session/message-queue.ts:16-379`。
- **Steering**：队列项默认等待当前回复完成；用户显式点“立即发送”后，纯文本且锚定于当前会话路径的条目才会被当前生成取得。系统先把该用户消息持久化，再将其转换为模型消息注入后续 step；带附件、队列暂停或属于另一 fork 的条目不参与。实现见 `src/renderer/stores/session/steering.ts:78-154` 与 `message-queue.ts:452-552`。
- **Chat/Work 分流**：模式策略只在 Work Mode 开放 queue 与 steering；Chat Mode 不再承诺队列，但会继续排空模式拆分前已持久化的旧队列，避免顺序倒置。策略见 `packages/chatbox-core/src/session/mode-policy.ts:19-79`，输入决策见 `src/renderer/components/InputBox/submitAction.ts:39-83`。
- **同会话主链锁**：普通提交、生成和重新生成仍由会话级锁保护；替代回复可绕过该锁并行运行，消息写入由 UpdateQueue 串行合并。并行回复中只有一个实例可注册 steering consumer，避免重复消费队列项。
- **多会话并行**：生成锁与消息队列都按 session 隔离，不同会话互不阻塞；图像生成等后台任务另走 chatbox_cli 回填链，不与文本消息队列共用调度器。
- **流排空等待**：新生成在启动前会等待同会话未结算的 stream drain（`orchestration.ts:594-608`，可被自己的停止按钮中止等待），保证前一次停止的工具残留不会与新生成交错。
- 队列可跨刷新恢复，但本次未运行验证崩溃、多个窗口同时消费以及外部 Provider 长时间不结束时的实际时序。

## 9. Agent、工具、知识库与附件注入点

### 9.1 Copilot：以系统提示词模板实现，复用普通 chat 会话

`CopilotDetail`（`src/shared/types.ts:94-110`）的字段如下（`picUrl` 已标记 deprecated）：

```ts
{ id, name, prompt, picUrl(deprecated), avatar, backgroundImage, description,
  tags, screenshots, createdAt, updatedAt, usedCount, sourceId, starred }
```

选中一个 copilot 时（`routes/index.tsx:211-234, 302-306`，后者为用量上报），行为是把 `session.copilotId` 设成该 id，并把 `session.messages[0]` 设成 `{ role: 'system', contentParts: [{type:'text', text: copilot.prompt}] }`。创建出来的仍然是一个普通 `type: 'chat'` 的 Session，只是多了一个 copilotId 字段用于用量统计。

### 9.2 知识库：前端只持有 id/name 句柄，检索以工具形式注册

前端状态只是 `Pick<KnowledgeBase, 'id'|'name'>`，没有把知识库内容拉到前端。真正生效的地方是生成阶段的 `buildToolsForSession`（`stores/session/tools-builder.ts:241, 246-253`），判定逻辑见下方代码块：

```ts
const kbSupported = Boolean(knowledgeBase) && model.isSupportToolUse('knowledge-base')
...
if (knowledgeBase && kbSupported) {
  kbToolSet = await getKBToolSet(knowledgeBase.id, knowledgeBase.name)
}
```

即知识库是作为**一个模型可调用的工具**注册进去的（`getToolSet as getKBToolSet` 来自 `@/packages/model-calls/toolsets/knowledge-base`），依赖模型是否支持 `'knowledge-base'` 这个 `ToolUseScope`（`src/shared/types/session.ts:227`：`ToolUseScopeSchema = z.enum(['agent','web-browsing','knowledge-base','read-file'])`）。

### 9.3 网页浏览：每会话布尔开关 + provider 默认值

生成时先由 `getSessionWebBrowsing`（`stores/session/utils.ts:33-40`）解析出本会话的网页浏览开关：有显式设置就用显式设置，否则 ChatboxAI 的会话默认开启、其他 provider 默认关闭。随后在 `tools-builder.ts:242-306` 判断该开关与模型是否支持 `'web-browsing'`，两者都满足才注册 `web_search / parse_link` 工具（后者取决于所选搜索 provider 的能力）。界面上的默认值规则与按钮状态见 Chat UI 笔记。

### 9.4 三者收敛到同一条流水线

Agent 模式、知识库、网页浏览三个开关最终都汇入同一次调用：`orchestration.ts:713` 的生成准备流程，内部统一走 `buildToolsForSession`（`agent-harness.ts:215, 306-317`）。Agent 模式本身由会话的工作模式输入结合平台与模型能力收敛（`agent-mode.ts`）。工具注册顺序（`tools-builder.ts:291-365`）：

- MCP（仅 agent 模式）；
- `web_search`/`parse_link`（独立于 agent 模式）；
- 知识库；
- session-attachment RAG；
- 文件读取；
- code_execution；
- 文件系统；
- skills/`user_exec`/`install_skill`（仅 agent 模式）。

### 9.5 工具审批的暂停语义

`MAX_TOOL_CALLS_BEFORE_CONFIRMATION = 25`（`shared/utils/tool-call-limit-pause.ts:7`）：一次生成里，工具调用达到 25 次才会暂停要求用户确认，且暂停会冻结同一 step 里**整批**并行工具调用而不是单个——这条限制是在"普通 chat 模式"的 `orchestrateGeneration` 里实现的（`withToolCallLimitPause` 包装，`orchestration.ts:750-752`），说明 chat 与 agent 在实现上没有清晰边界。

`pauseOnToolCallLimit` 设置可**按会话覆盖或全局关闭**该确认点（判定见 `tool-call-limit-pause.ts:14-19`，全局默认 true）；关闭时工具不再被该包装。继续按钮拆分为"继续/继续并本次不再暂停确认"（`orchestration.ts:1170-`）。暂停类审批（`user_exec / file_mutation / app_action`）不受该开关影响，暂停状态随消息以 `finishReason: 'tool-call-paused'` 落盘（第 6 节）。审批的界面工作流见 Chat UI 笔记；工具执行循环内部语义属于 Agent 工具类目。

### 9.6 Agent 模式建议（本次新增核实）

会话的 `agentMode` 为 auto、且本次是首轮用户消息时，`orchestration.ts:636-711` 会在正式生成前先用分类器模型判断是否建议开启 Agent 模式。判定为建议时，目标消息不再进入模型生成，直接以 `agent-mode-suggestion` part 和 `finishReason: 'agent-mode-suggested'` 收口落盘，接受或拒绝在 UI 的建议卡（`Message.tsx`）上处理。分类器模型可独立于会话模型，其参数按实际运行模型的作用域解析。

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
- `src/renderer/stores/session/messages.ts`（疑似死代码）
- `src/renderer/stores/src/renderer/stores/session/`（`mergeCachedGeneratingMessages`）
- `src/shared/context/builder.ts`、`compaction-points.ts`
- `src/renderer/packages/context-management/`（`compaction-detector.ts`、`compaction.ts`、`compaction-boundary.ts`、`compaction-commit.ts`）
- `src/shared/types/session.ts`（`ToolUseScopeSchema` 等）、`src/shared/utils/tool-call-limit-pause.ts`
