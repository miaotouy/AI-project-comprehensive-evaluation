# AIO-Hub 对话请求与上下文调查笔记

> 调查对象：`https://github.com/miaotouy/aio-hub`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`03cf4b6e028d0e23d5447a7c0cd7678aab07af3f`（分支：`dev`）
>
> 调查方式：对照源码快照差异，只读复核预设组装、实发捕获、预览、媒体附件、VCP分段和会话级压缩执行；既有世界书与其它主链保留就近静态依据；未运行模型请求或应用
>
> 调查范围：生成任务的提交入口、上下文拼装管道、预算与压缩、流式消费与节流落盘、完成与回写、停止/重试/续写执行链、队列与并发、外部能力注入点；会话数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- 提交入口是 useChatHandler.sendMessage：上下文管道把 11 个处理器按 priority 拼装成请求，交给执行器发往模型，流式回调写回后再由节流落盘。
- 渲染与持久化是**两套独立节流**：流缓冲经 RAF 节流后直送界面，屏幕显示几乎实时；正文 chunk 先进入缓冲区，再由定时器按增量保存间隔或默认 2 秒写入节点 content，最后落盘。崩溃时可能丢失最后几秒流式内容——`content` 字段本身滞后于屏幕显示。
- 上下文压缩是**非破坏性遮罩**：只压当前活动路径，摘要由独立 LLM 请求生成，原消息保留可恢复。两个自动检查点加一个手动入口；连续压缩时旧摘要作为 previous_summary 传入续写模板、新摘要创建后旧摘要一并隐藏。
- 目标父节点到根的路径仍在生成时再发消息会**排队**：本次生成调用被跳过，排队标记随节点持久化（`metadata.isQueued`），同一会话的其它分支可继续并行。调度器扫描这些持久化标记，在该路径空闲后按 queueReplyMode 合并或链式触发，触发本身还受 autoTriggerGenerationAfterQueue 设置控制（默认开启）。
- 工具调用审批把执行挂在 Promise resolver 上：审批请求返回 Promise，界面点击时才 resolve，工具执行流程用 await 原地等待；编排循环内部语义已由 Agent 工具笔记承接（`toolCallingStore.requestApproval`）。
- 纯图片用户消息若在附件解析后没有有效文本，默认只在请求副本中补充占位文本，以兼容拒绝空文本的上游 API；原消息正文和资产不被改写。该行为可由请求设置关闭（`asset-resolver.ts:182-249`、`defaultSettings.ts:162`）。
- 节点在请求发出后、收到首个有效流式内容前处于 waiting，收到内容后切到 generating；两者都由节点状态驱动 UI 骨架与流式表现，最终统一收口为 complete 或 error。
- 单节点执行器按可重试的 HTTP 状态码白名单决定是否重试：有明确状态码但不在配置白名单（默认 429/5xx 系列的一部分，retryStatusCodes 可改）时直接报错，2xx/504/524 始终排除；无状态码的网络/超时错误不受该限制。命中限流时在退避基础上追加惩罚等待（`useSingleNodeExecutor.ts:557-610`、`utils/retryStatusCodes.ts`）。
- 压缩的保护区与单次压缩量可按消息条数或**用户回合**计数（countUnit）：回合包含该用户消息后的助手回复与工具结果，原生工具调用与 VCP 拆分消息都归入同一回合；两种单位各自记忆数量设置（`useContextCompressor.ts:125-180`、`types/llm.ts:388-426`）。
- 请求由 useLlmRequest 编排，再按 profile.type 与模型 binding 分发给对应适配器；输出预算取共享核心 output-tokens.ts 的默认值 65,536，按模型的 tokenLimits.output 裁剪，协议层再按模型声明的采样能力过滤参数（细节见第 4 节）。

## 系统边界与生成任务主链

```text
sendMessage（useChatHandler：Agent 配置、附件等待、压缩检查点 1）
  -> 创建用户消息节点 + 占位助手节点（generatingNodes.add -> updateActiveLeaf -> executeRequest）
  -> 上下文拼装：session-loader 两遍回溯（压缩遮罩）+ contextPipelineStore 11 处理器按 priority 执行
  -> useChatExecutor / useSingleNodeExecutor 执行（模型过滤、前缀续写、工具循环检查点 2）
  -> handleStreamUpdate：正文 delta -> 渲染流缓冲（消息渲染器笔记 2）+ persistBuffer/syncBuffer（节流写回）
  -> finalizeNode 强制 flush 全部缓冲并落盘（含 continuation 前缀补回）
  -> llmChatStore watch generatingNodes.size 减少 -> 触发排队任务（queueReplyMode）
```

边界：节点/会话如何持久化、分支指针与索引在 [`../会话与消息管理/AIO-Hub-会话与消息管理调查笔记.md`](../会话与消息管理/AIO-Hub-会话与消息管理调查笔记.md)；发送按钮、审批条等界面反馈在 [`<../Chat UI/AIO-Hub-ChatUI调查笔记.md>`](<../Chat UI/AIO-Hub-ChatUI调查笔记.md>)；流缓冲到正文渲染的最后交接在 [`../消息渲染器/AIO-Hub-消息渲染器调查笔记.md`](../消息渲染器/AIO-Hub-消息渲染器调查笔记.md)（2 节）；工具执行循环内部语义在 [`../Agent工具/AIO-Hub-Agent工具调查笔记.md`](../Agent工具/AIO-Hub-Agent工具调查笔记.md)。

## 1. 提交入口、任务对象与状态机

`useChatHandler.sendMessage()`（`composables/chat/useChatHandler.ts:94-612`）是主提交入口，创建任务对象的顺序：

1. 读取 Agent 配置；附件尚未导入完成时先等待（9.1）；
2. 压缩检查点 1：创建新用户消息前调用一次（附录 A.1），保证本轮请求可以使用刚生成的摘要；
3. 创建用户消息节点与占位助手节点（createMessagePair），把占位节点加入生成集合、更新活动叶子，最后才真正发起请求。这个顺序保证界面立刻出现"等待中"的占位气泡，即使网络请求还没发出；
4. 请求发出后节点停在 waiting，收到首个有效流式内容时由响应处理器切到 generating，中途失败或结束再收口为 error 或 complete（第 5、6 节）；
5. 若目标父节点到根的路径仍含生成节点，走排队分支：消息节点照常创建并持久化，实际 LLM 请求被跳过，节点打上 metadata.isQueued 标记且 status 写为 queued；切换到其它空闲分支则可直接执行（`useChatHandler.ts:540-580`，见第 8 节）。

执行器分两层：`useChatExecutor` 负责发起 LLM 请求并做附件与 Token 的前置处理（入口 `executeRequest`，`useChatExecutor.ts:92-180`），下层 `useSingleNodeExecutor` 承担单次请求与重试策略，前缀续写也由它发出（`useSingleNodeExecutor.ts:128-700`）。Provider 与协议 Adapter 层见第 4 节。

## 2. 历史选择与上下文拼装顺序

发送给模型的内容由历史选择与管道拼装共同决定：

- **历史选择**：`getBranchHistory` 分两遍回溯构建请求上下文——第一遍从叶子向上收集所有"已启用压缩节点"遮罩的消息 ID，第二遍跳过这些原消息、保留摘要节点（压缩的"非破坏性遮罩"语义，见附录 A.2）。tool 角色按配置转成 user；工具调用中间助手节点的 reasoningContent 保留，普通最终回答则去掉；服务端分段调用通过同请求的工具子节点识别中间助手；可选把旧消息 HTML 转成 Markdown 以省 token（`core/context-processors/session-loader.ts:149-215`）。
- **上下文管道**：管道 store 注册并按 priority 排序执行 11 个处理器（排序由 sortedAndEnabledProcessors 完成，`contextPipelineStore.ts:49-219`）。当前默认顺序：
  1. 会话加载（100）；
  2. 异步任务结果（110）；
  3. 正则（200）；
  4. 转写/文本提取（250）；
  5. 世界书（300）；
  6. 预设注入组装（400）；
  7. Recall 检索（450，原 `knowledge-processor` 已被 `recall-processor` 替换，见 9.6）；
  8. 会话变量（500）；
  9. Token 限制（600）；
  10. 消息格式化（800）；
  11. 附件解析（10000）。
  启用状态和用户调整后的顺序持久化到 `llm-chat/pipeline-settings.json`（配置界面 PipelineConfig.vue 见 Chat UI 4.4）。压缩发生在这个管道之前，由会话加载器把原消息替换为摘要；图片的实际缩放与 Base64 化在管道末端才发生（9.3）。

## 3. 预算、截断、摘要与压缩（模型、入口与不变量）

主文保留配置模型、触发入口与关键不变量，触发/执行细节见附录 A：

- **配置模型**：压缩是 **Agent 级配置**，字段位于 LlmParameters.contextCompression，生效优先级为"调用参数 > 当前选中 Agent 的配置 > 默认值"，由 useContextCompressor.getEffectiveConfig() 计算（`useContextCompressor.ts:424-460`）。
- **计数单位**：保护区与单次压缩量可按消息条数或**用户回合**计数（countUnit）。用户回合把该用户消息之后的助手回复与工具结果合并计为一条，原生工具调用和 VCP 拆分消息都按同一规则归并；两种单位各自记忆数量设置，默认按消息条数（`useContextCompressor.ts:125-180`、`types/llm.ts:388-426`）。
- **触发入口**：自动检查点有两处——一处位于 sendMessage() 创建新用户消息之前，一处位于单节点执行器完成助手节点之后（工具循环中的单节点执行也经过后者）；输入框"更多"菜单另提供 manualCompress() 手动入口。两处自动检查点都捕获压缩错误，摘要请求失败不会阻断正常聊天（`useChatHandler.ts:465-480`；`useSingleNodeExecutor.ts:690-700`；`useContextCompressor.ts:501-509`）。
- **任务与路径**：压缩是按会话登记的独立异步任务，同一会话重复触发复用运行中的 Promise；发送前先等待既有压缩，再按提交的父节点路径检查，手动入口默认取活动叶子。完成后的自动检查不再阻塞已完成的回复。只遮罩目标路径，不删除旧消息；禁用压缩节点可让原消息重新进入上下文。取消贯通任务控制器与摘要请求，并在 Token 计算后、改树前再次检查（`session/sessionRuntimeManager.ts:63-151`；`useContextCompressor.ts:455-505`）。
- **已确认边界**：连续压缩的"增量摘要滚动合并"已接入执行路径——executeCompression() 会把本次压缩范围之前最近的已启用摘要节点作为 previousSummary 传入续写模板，新摘要创建后旧摘要一并隐藏；仓库文档 src/tools/llm-chat/docs/architecture/context-compression.md 已同步，文档与实现一致。仍存在的边界：后台会话自动压缩可能读取前台会话或 Agent 的配置与 Token 统计（状态依赖错位）。两者详情见附录 A.3/A.4（`useContextCompressor.ts:580-640`）。

## 4. SDK、Provider、模型与协议交接

- 请求编排：`useLlmRequest` 调用共享核心 llm-core，按 profile.type 与模型 binding 选择适配器；OpenAI 兼容家族多数共用 openAiAdapter，Gemini、Anthropic、Cohere、Vertex、OpenRouter 等各有适配器，virtual channel 在路由前把聚合预设映射到实际渠道（虚拟渠道机制见 LLM 渠道管理笔记）。
- 输出预算：共享核心 `output-tokens.ts` 提供 65,536 的默认输出预算、1,000,000 的编辑范围常量，并按模型的 tokenLimits.output 裁剪；桌面端在选定物理模型后裁剪 maxTokens 与 maxCompletionTokens，未知输出限制时保留显式预算。新默认值只影响新建与缺省配置。
- 采样参数兼容：请求入口按模型声明的 supportedFeatures.parameters 过滤未声明的字段，`sampling-compatibility.ts` 补充已知模型与推理模式约束，协议层在合并额外参数后清理冲突。协议层省略调用方未提供的温度，Gemini 的可选输出预算交给服务端默认值，Anthropic 缺省 max_tokens 时使用共享预算；OpenAI Chat Completions 映射到 max_completion_tokens，Responses 映射到 max_output_tokens。
- 模型能力过滤：`filterParametersForModel` 按目标模型支持的参数过滤，这是"切换模型重试"的实现基础（第 7 节）。
- 前缀续写：续写节点以 prefix 模式调用支持前缀续写的 API，从已写入的前缀之后继续生成（`useSingleNodeExecutor.ts:313`；节点语义在会话管理 4.3）。
- 重试：单节点执行器按 `retryStatusCodes` 白名单与退避策略重试，详见第 1 节与 `useSingleNodeExecutor.ts:557-610`。
- 独立端点：DeepSeek 网页工具（搜索/抓取）走 `src/llm-apis/adapters/deepseek/tools.ts` 的独立调用，复用渠道连接与传输层但独立于 Chat Completions 消息协议，详情见 Agent 工具笔记。
- 翻译：独立请求的模型选择优先级见 9.7。

### 4.1 预设编译与缓存友好的请求排列

预设先按组启停与模型匹配筛选，组合正文按片段选中版本物化，再做宏展开和注入；动态历史锚点共用不可变历史坐标，并避开工具调用/结果保护区间。开启上下文缓存优化后，自动工具定义/用法保持在前部，自动运行环境与自动 Recall 尽量放到靠近尾部的安全参考块；手写宏和显式 Recall 仍保留原布局。日期时间预设宏可按显示窗口冻结，减少高频变化。请求最终仍经过预算、格式化和附件解析，缓存命中需由真实上游 usage 验证（`core/context-processors/injection-assembler.ts:216-379`；`core/context-utils/runtime-context.ts`）。规则细节见[上下文编译与提示词工程](<../上下文编译与提示词工程/AIO-Hub-上下文编译与提示词工程调查笔记.md>)。

## 5. 流式事件、缓冲、节流与顺序

### 5.1 服务端 VCP 分段与本地工具循环的边界

同一次网络响应可以包含多段助手/工具输出。执行器按段索引分配节点：第一段复用占位节点，后续段结束前一段后追加为子节点，并迁移排队子树，让排队路径继续依赖当前生成标记。每段保存同一请求 ID、角色、响应 ID、结束原因与工具状态，流缓冲随活动段切换；最终用一份请求快照关联全部响应节点（`useSingleNodeExecutor.ts:337-470`）。

服务端工具结果区段由流层识别，并在本地调用解析前被遮蔽；标准工具请求才进入本地执行。该分段与本地“执行工具后再发网络请求”的编排分属两条主链：服务端响应在节点树上按段展开为占位节点与后续子节点，本地工具循环只处理解析后的标准工具请求。解析约束见[Agent 工具](<../Agent工具/AIO-Hub-Agent工具调查笔记.md>)。

流式正文和持久化更新分离的具体机制在 `composables/chat/useStreamingMessageSources.ts` + `useChatResponseHandler.ts`（渲染侧的显示交接见消息渲染器笔记 2 节，这里记录执行与落盘侧）：

- **渲染通道**：useStreamingMessageSources.ts 维护一张模块级的流源映射表（sources，键为节点 ID），**完全独立于节点持久化的 content**；渲染层只通过 getOrCreateStreamingMessageSource 取用流源，MessageContent.vue 仅在节点处于生成中时创建或获取（细节见渲染器笔记 2.1；`useStreamingMessageSources.ts:119-150`）。
- **持久化通道**：useChatResponseHandler.handleStreamUpdate() 对正文（reasoning 之外）分支把 chunk 同时写入同一更新缓冲里的两个子缓冲：persistBuffer 负责落地节点内容，syncBuffer 负责跨窗口同步。节流分两路（`useChatResponseHandler.ts:114-330`）：
  - **跨窗口同步**：scheduleStreamSync() 用 requestAnimationFrame 节流，把 syncBuffer 通过窗口同步总线以 chat:streaming-delta 事件广播给分离窗口，主窗口与悬浮输入框窗口据此共享生成状态；
  - **内容落盘**：scheduleContentFlush() 用定时器延迟写盘，延迟由 getContentPersistDelay() 计算：开启增量保存时取增量保存间隔（下限 250ms），否则固定 2000ms。延迟到期后，flushContentToNode() 把 persistBuffer 写入节点 content，再触发按配置节流的增量落盘。

渲染路径（流缓冲区 → RAF 节流 → UI）与持久化路径（chunk 缓冲 → setTimeout 节流 → 节点 content → 落盘）是两套独立的节流策略：渲染更新几乎实时（RAF 级别），持久化写盘则明显更慢（默认 2 秒或用户配置的增量保存间隔）。应用崩溃时可能丢失最后几秒的流式内容——`content` 字段本身滞后于屏幕显示。

- **reasoning 不对称**：reasoning（思考内容）走另一套 RAF 节流缓冲（`reasoningUpdateBuffer`，声明在 `useChatResponseHandler.ts:42-45`，处理分支在 260-310），没有单独的"流源"抽象，而是每帧把 buffer flush 进 `node.metadata.reasoningContent`，因此 reasoning 写入节点的频率高于正文（每帧对比默认每 2 秒）。

## 6. 完成、异常、半截流与最终回写

- `finalizeNode()` 在生成结束时**强制 flush 所有缓冲区**（正文与 reasoning 各自写回节点），确保最终落盘内容完整；过程中的中间态可能因节流未落盘（第 5 节）。同一个函数还会对标记为续写、返回内容却没有包含原前缀的节点手动补回前缀，防止模型漏复述前缀导致内容断裂（节点语义在会话管理 4.3；`useChatResponseHandler.ts:457-718`）。
- 响应中的 Base64 内联图片由 finalizeNode 内的 processInlineData 转成附件追加到节点；usage 为 0 但确实有内容时，再用本地 token 计算修复（`useChatResponseHandler.ts:330-520`）。
- 生成结束后，llmChatStore 中对生成节点数量减少的 watch 会触发排队任务处理（第 8 节）；同一处 watch 也是僵死节点修复的触发点（`llmChatStore.ts:154-190`；数据语义在会话管理 9 缺陷 1）。
- 半截流的错误诊断（错误与空响应诊断存 metadata）见消息渲染器笔记 1.1；执行侧的异常分支 handleNodeError 区分超时、abort 与普通错误，写入 metadata.error 并在清理缓冲后收口。工具编排层的异常由 orchestrate 的 catch 统一转交给它（`useChatResponseHandler.ts:719-770`；`useToolCallOrchestrator.ts`）。

## 7. 停止、重试、续写与重新生成

- **重新生成（regenerateFromNode）**：useChatHandler.regenerateFromNode() 先取 Agent 配置，调用方传入 modelId 或 profileId 时覆盖模型，再用 filterParametersForModel 过滤出目标模型支持的参数——这就是"切换模型重试"的执行链（UI 层的"切换模型重新生成"按钮在 Chat UI 6.1）。节点语义（给同一用户消息新增兄弟助手节点）在会话管理 4.3（`useChatHandler.ts:613-770`）。
- **续写（continueGeneration）**：useChatHandler.continueGeneration() 对 assistant 节点新建一个内容等于原内容、标记为续写的兄弟节点，发送时以 prefix 模式调用支持前缀续写的 API，从 continuationPrefix 之后继续生成；对 user 节点则是"角色接力"，新建空子节点。最终内容的前缀补回在 finalizeNode 完成（第 6 节；`useChatHandler.ts:771-895`）。
- **停止/abort**：中止控制器集合（abortControllers）挂在会话运行时管理器上（数据语义在会话管理 6）。停止入口是 llmChatStore 的 abortSending 与 abortNodeGeneration，先拒绝挂起的审批，再中止正在执行的节点：有内容的半截回复结算为 complete，无内容则写入“用户手动停止”。会话级停止还会扫描未执行的排队节点，移除 isQueued 标记并写入“队列已停止”，同时清理会话排队集合，避免中止后又被调度器触发（`llmChatStore.ts:748-770`；`sessionRuntimeManager.ts:23-168`）。网络级中断是否到达上游服务仍未核实。

## 8. 队列、多会话并发与后台生成

`sessionGenerationManager.ts` 的排队机制分三部分：

- **排队写入**：发送入口发现目标父节点到根的路径仍在生成时，改为只落库不请求——消息节点照常创建并持久化，真正的请求调用被跳过，节点同时打上排队标记；标记位置随模式走，combined 模式标在 user 节点上，chained 模式标在占位 assistant 节点上（`sessionGenerationManager.ts:290-330`、`useChatHandler.ts:540-580`）。

  这些标记分三处落地：入队集合 queuedSessionIds、调用参数 skipGeneration（跳过本次生成），以及节点上的 metadata.isQueued 与 status 的 `queued` 字面量。旧数据里的 `pending` 状态在展示层仍按 queued 兼容；入口函数是 sendMessage()。
- **触发条件**：当前生成结束（llmChatStore 监听生成节点数量减少）且设置项 autoTriggerGenerationAfterQueue 为真（`llmChatStore.ts:195-240`）。
- **触发执行**：调度器扫描节点上的持久化排队标记，只启动没有排队祖先且目标路径已经空闲的节点，因此同一条排队链保持顺序，其他分支仍可并行。扫描入口是 triggerQueuedGenerationForSession()，同时识别 isQueued、queued 与兼容旧数据的 pending 三种写法（`sessionGenerationManager.ts:134-268`）。

  恢复动作按节点内容分流：内容为空的 Assistant 占位节点直接复用（`reuseNode`），已有部分内容的节点改走续写分支；user 节点走 `regenerateFromNode`（合并回复），assistant 占位节点走 `continueGeneration`（链式追加），由 `queueReplyMode` 的 `"combined"`/`"chained"` 决定，默认 combined。

多会话并行：`generatingNodes` 是节点粒度集合，会话间互不阻塞（数据语义在会话管理 6）。排队与等待的可见 UI 提示有明确实现：`utils/messageStatus.ts` 把 queued/waiting 映射为"排队/等待"徽标，`MessageHeader` 按 `showMessageStatus`（默认开启）展示（Chat UI 5.2）。

## 9. Agent、工具、知识库与附件注入点

### 9.1 附件发送前等待

`useChatExecutor.processUserAttachments()`（`composables/chat/useChatExecutor.ts:209-250`）：等待所有附件的 `importStatus` 变成非 pending/importing（`waitForAssetsImport`，30 秒超时，`useChatExecutor.ts:181-205`），超时抛错阻断发送。附件两阶段导入的状态机在会话管理 8.3。

附件解析完成后，如果用户消息只包含图片且正文为空，`asset-resolver` 默认给请求副本补一段占位文本。补位只在图片已成功解析、没有转写文本和其他媒体时发生，目的是兼容拒绝空文本的 API；设置项 `imageOnlyMessagePlaceholder` 可关闭，持久化消息正文不变（`core/context-processors/asset-resolver.ts:229-249`、`types/settings.ts:302-303`）。

### 9.2 转写注入

`useTranscriptionManager.ts` 负责发送前转换：支持图片、音频、视频、PDF 和 DOCX，转写模型按"类型专用模型 → 转写兜底模型 → Chat 全局默认模型 → 当前会话/Agent 模型"四级选择（`getTranscribeModelIdentifier`，`useTranscriptionManager.ts:72-99`）。两种策略：

- **smart（默认）**：模型原生不支持该模态时才使用转写；较老的附件超过 `forceTranscriptionAfter`（默认 10 条，`config/defaultSettings.ts:117`）后可强制转写；已有转写且 `smartPrioritizeTranscription` 为真（默认 true）时优先发文本（`useTranscriptionManager.ts:465-507`）。
- **always**：始终使用转写（`useTranscriptionManager.ts:424`）。

实际发送在执行管道前调用 `ensureTranscriptions()` 等待必要任务，管道中的转写处理器再把文件占位符或附件替换为已有转写/文本提取结果。上下文预览只沿管道读取已有结果，不启动或等待缺失转写；统计用途还延后媒体二进制解析并标记估算（`useSingleNodeExecutor.ts:234-278`；`useChatExecutor.ts:423-438`）。附件卡片的单项重试/取消与批量转写属于界面工作流。

### 9.3 图片压缩

与上下文摘要无关，是 Agent 参数 `imageCompression` 控制的发送前二进制处理。管道最后的 `asset-resolver.ts`（priority 10000）先按模型 `maxImageDimension` 做安全缩放（`asset-resolver.ts:46-57`），再按用户配置执行最大边限制、保持原格式或转为 JPEG/WebP，并可设置 0.1-1.0 的有损质量（默认 0.85，`asset-resolver.ts:70-81`）；失败时保留当前图片继续发送。处理发生在请求用的图片 buffer 上，没有改写资产管理器中保存的原文件。

### 9.3.1 长图切片、虚拟文本与本地媒体

长图切分在图片缩放/编码前执行，按请求设置和原图尺寸生成切片计划，再逐片走同一图片处理链。它只改变此次请求的图片 part，原资产保持不变；任一切片失败整组回退原图，避免发出残缺切片。不可变资产最多缓存 64 份计划，可变本地文件只在请求内复用；统计预览只取缓存计划或估计，不主动解码长图（`core/context-utils/image-slicing.ts:66-144,209-289`；`asset-resolver.ts:238-249`）。

长文本粘贴和跨工具发送可生成节点内的虚拟文本附件，不必先创建资产文件。会话加载把它转为管道附件，文本处理阶段和 Token/摘要/可读导出使用相同围栏包装；默认转换阈值 3000 字符，单份最多 16 MiB、最多 100 份，运行时导入/同步数据经过规范化校验。文本附件自己的长反引号围栏会决定包装围栏长度，以保留原文本边界（`utils/virtualAttachments.ts:5-89`；`session-loader.ts:330-342`）。

工具返回的本地媒体引用与资产附件分别保存，但在会话加载时同样投影为请求附件。若工具消息携带媒体或属于服务端 VCP 工具段，即使通用 tool→user 开关关闭也会转为用户消息以承载多模态；原角色留在内部历史标识，供动态锚点和 Recall 识别，最终适配器不应把这些内部字段视为模型内容（`session-loader.ts:295-344`）。

### 9.4 会话变量注入

Agent 开启 `variableConfig` 后，`variable-processor.ts`（priority 500）解析消息中的 `<svar name="player.hp" op="-" value="10" />` 标签，支持赋值和 `+ - * /` 运算，并按变量定义的 min/max 截断；`$[player.hp]` 读取单值，`$[svars::json|table|list]` 输出全部非隐藏变量。处理器从活动分支最近的 `metadata.sessionVariableSnapshot` 起点继续回放，所以切分支后能按该分支历史重建状态；含变更的消息会写快照，压缩节点即使没有新变更也强制写一份锚点快照（快照字段数据语义在会话管理 1.3）。消息菜单的"变量快照"和上下文分析器的"变量状态"页是这套数据的可视化入口（Chat UI 6.3）。

### 9.5 工具调用审批暂停与编排循环

分两层：

- **状态层**：审批挂在 Promise 上——`requestApproval(sessionId, request, externalId?, options?)` 返回 Promise（`toolCallingStore.ts:148-187`），工具执行流程用 `await` 直接卡住等待用户点击，省掉状态机轮询。

  store 文件为 `stores/toolCallingStore.ts`，待审请求数组类型 `pendingRequests: PendingToolRequest[]`，每条的 resolver 声明 `resolve: (result) => void`。

  界面上的批准与拒绝动作（单条入口 approveRequest 与 rejectRequest，另有按 ID 批量的两个版本）只在用户点击时才 resolve 对应的 Promise。相关行为（`toolCallingStore.ts:189-225`）：
  - **可配置超时**：审批默认无限等待（toolApprovalTimeoutEnabled 为 false）；开启后按 toolApprovalTimeoutSeconds 定时自动拒绝，该值范围 5 秒到 24 小时、默认 60 秒，调用方也可显式传入 timeoutMs 或 AbortSignal（`toolCallingStore.ts:25-133`）；
  - **批量拒绝**：会话删除或清理时按 sessionId 批量拒绝（cancelBySession），窗口关闭触发的 beforeunload 与 pagehide 事件则全部拒绝（`toolCallingStore.ts:227-277`）；
  - **VCP 兼容**：VCP（通过 WebSocket 连接的外部协议）广播过来的审批请求靠 externalId 识别——这类请求的 sessionId 是 vcp-${maid} 格式，与本地 llm-chat 会话 ID 体系分属两套，审批条 UI 因此不按 sessionId 精确匹配（见 Chat UI 5.3）。
- **编排层**：编排器用"LLM 生成 → 检测工具请求 → 等待审批 → 执行 → 把结果拼回上下文 → 再请求"的循环驱动整个回合，循环上限由 toolCallConfig.maxIterations 控制，默认 5（`:111`）。

  - 入口是 composables/chat 下 useToolCallOrchestrator 的 orchestrate()（`useToolCallOrchestrator.ts:73-470`）。
  - 每轮处理：先用 parseToolRequests() 检测响应文本中的工具调用（VCP 或其他协议），命中后建一个 role 为 tool 的节点、把 metadata.toolCalls 的初始状态置为 `awaiting_approval`，再由 processCycle() 调用 requestApproval() 等待审批。
  - 交接：processCycle() 来自 `@/tools/tool-calling`，其内部的解析、校验、执行与结果格式化细节已由 [`../Agent工具/AIO-Hub-Agent工具调查笔记.md`](../Agent工具/AIO-Hub-Agent工具调查笔记.md)（同代码快照）承接。

审批开关的另一层是**自动决策仲裁**：配置允许时，审批请求可先交给 `src/services/decision-arbiter/` 的仲裁器判定自动批准/拒绝（JEV 问卷评估与普通 LLM 两种引擎）；自动批准/拒绝直接结算，只有升级人工或仲裁失败进入人工等待，人工审批超时会拒绝；外部来源（VCP 节点、文件传输）的请求带独立来源标记，不与应用内会话混用。仲裁细节与配置入口在 Agent 工具笔记第 6 节，本笔记只记"审批点位于队列与执行之间"这一交接位置。

### 9.6 外部能力注入概览（已确认入口，未逐分支展开）

| 功能 | 当前快照中确认的实现（注入点） |
| --- | --- |
| 世界书 | `worldbook-processor`（priority 300）合并全局、用户档案和 Agent 绑定的世界书，执行主/次关键词与正则匹配、selective/constant/概率、扫描深度、角色/名称/标签过滤、递归与延迟递归、sticky/cooldown/delay、包含组和加权选择，再按严格 depth 或降级 anchor 位置注入。`st-worldbook-manager` 编辑与导入的世界书数据由这条处理器实际消费。部分 ST 扩展字段仍只有表示/编辑能力，未找到运行时消费。 |
| Recall 思绪检索 | `recall-processor`（priority 450）解析 `【recall::...】` 严格占位符协议（`recall-placeholder.ts` 校验编码/参数/数值范围），执行检索并替换；Agent 配置 `autoInjectIfMacroMissing` 时按未引用绑定自动注入占位符到 `context_head` 或 `before_last_user`（`recall-processor.ts:151,180`）。原 `knowledge-processor` 已删除，旧 `【kb::...】`/`【knowledge::...】` 占位符只记录"已废弃"警告、不再执行检索。 |
| Skill 集成 | `skill-manager` 的 `SkillManagerProxy` 以 `skill:system` 注册到工具调用系统，提供动态激活及 `skill_read_file`/`skill_list_dir`/`skill_run_script`；复用 9.5 的审批/工具循环，不是独立消息协议。 |
| SillyTavern 兼容 | `sillyTavernParser.ts` 和 Agent 导入服务可解析 V2/V3 角色卡 JSON/PNG、提示词 `prompt_order` 和部分正则/宏；快捷操作导入还兼容 SillyTavern Quick Reply。独立 `st-worldbook-manager` 提供世界书编辑、持久化、JSON/`.lorebook` 与角色卡 PNG/AIO Bundle 导入、导出和 Agent/User Profile 绑定，受支持字段由上行 `worldbook-processor` 实际执行。兼容是可运行子集，不是完整复刻酒馆扩展/事件协议。 |

### 9.7 独立生成请求：消息翻译

`composables/chat/useTranslation.ts` 里的 `translateText`（`useTranslation.ts:37-127`）只做"调 LLM 翻一段文本"这一件事，不感知消息树结构。

模型选择按三级回退：配置的翻译专用模型 → 全局默认模型 → 报错要求用户手动选择。

提示词占位符为 `{targetLang}`、`{text}`、`{thinkTags}`；最后一项会展开成当前生效的思考标签列表（例如 `<think>...</think>`），让模型保留 XML 标签结构、只翻译标签内的文本（`useTranslation.ts:76-97`）。

翻译结果存消息 `metadata.translation`（字段语义在会话管理 1.3），界面入口与快捷交互在 Chat UI 6.1。

### 9.8 上下文分析器：预览与有限实发证据

分析器区分当前构建预览与历史实发记录。预览以所选节点为终点，选择节点历史模型或待发送临时模型、当前 Agent 配置和用户档案，重跑管道并统计 Token；不启动转写，统计模式延后媒体读取。变量处理器仍可写与历史节点共享的元数据，预览的副作用范围限于这些共享元数据（`useChatExecutor.ts:306-497`；`session-loader.ts:330-344`；`variable-processor.ts:180-195`）。

实发记录由单节点执行器在管道内采集来源/宏/处理器变换，并把记录器接到请求适配后的 `requestCapture`。同一个逻辑请求可有多个网络尝试；每次以独立 attempt ID 记录最终消息投影、逻辑/实际路由、完成/失败/取消状态与关联节点。只保存请求体投影和来源映射，URL 与 headers 不进入捕获；本地估计 usage 与 Provider 报告分开。默认开启记录、关闭文本预览，并受容量上限裁剪，故它是有限诊断证据而非完整流量归档（`services/requestSnapshotRecorder.ts:23-137`；`services/requestSnapshots.ts:20-29`）。

缓存/变化分析比较这些实发快照；公共前缀属于本地估算，实际缓存读写以 Provider usage 为证据。预览与某个过去请求可能因配置、路由、异步结果变化而不同。持久化、清空和迟到写入处理见[会话与消息管理](<../会话与消息管理/AIO-Hub-会话与消息管理调查笔记.md>)，预设编译与动静分离见[上下文编译与提示词工程](<../上下文编译与提示词工程/AIO-Hub-上下文编译与提示词工程调查笔记.md>)。

### 9.9 显式 Knowledge 资料引用

Composer 的 Knowledge 引用（`knowledgeReference`，UI 在 Chat UI 3.1）随消息进入 `sendMessage`：先建一个 `role: "tool"` 的显式工具事件节点，再进入正常生成链。节点创建、检索执行与失败回写都在 `useChatHandler.ts:227-365`。

节点入口是 `services/explicitKnowledgeReference.ts:31` 的 `createExplicitKnowledgeToolEvent`；两种引用模式分别由 `executeKnowledgeReferenceSearch`（资料检索）与 `executeKnowledgeReferenceResearch`（研究，带轮次进度、可中止）承担，完成后结果写入该 tool 节点，失败则错误写回并阻断本轮生成。

## 10. 退出恢复、日志与已确认边界

- 切换会话、关闭窗口、应用退出时的任务收尾（未完成请求如何 abort/落盘）本次未调查；崩溃后残留 generating 节点的数据语义在会话管理 9 缺陷 1。窗口关闭时挂起的工具审批会被 `beforeunload` 拒绝（9.5）。
- 日志/trace/用量与具体任务的关联：本次未调查（`inspectorContext` 携带 `sessionId`/`purpose` 进入请求层，但本次未核实其消费方）。
- 分离窗口断连时流缓冲仍在主进程内存中，重连后的回放取决于订阅时机（Chat UI 8.2；渲染侧重放机制在渲染器笔记 2.1）。
- 已确认边界汇总：后台压缩状态依赖错位（附录 A.4）；`@/tools/tool-calling` 内部实现与 VCP 协议细节本次未展开（已由 Agent 工具笔记承接）；Provider 协议 Adapter 层本次只核实到请求编排、输出预算裁剪与采样兼容三处（第 4 节），各协议消息格式转换细节仍未展开。压缩文档与实现的"增量摘要"不一致已确认修复（附录 A.3）。

## 11. 未验证事项

- 网络级停止效果（AbortController 实际中断层）、停止后半截消息的最终落盘形状需运行验证。
- 队列触发（`triggerQueuedGenerationForSession`）在并发/切换会话场景下的竞态未做运行时复现。
- 压缩在多会话并行生成时的误压缩风险未复现（附录 A.4）。
- 转写、图片压缩、压缩摘要等未实际调用模型验证；导入导出往返与原子写的真实崩溃行为未验证。

## 12. 关键源码索引

- `src/tools/llm-chat/composables/chat/useChatHandler.ts`（sendMessage/regenerate/continueGeneration，94-995行）
- `src/tools/llm-chat/composables/chat/useChatExecutor.ts`（92-520行）、`useSingleNodeExecutor.ts`（128-700行）
- `src/tools/llm-chat/composables/chat/useChatResponseHandler.ts`（流式节流/finalize/错误处理，42-790行）
- `src/tools/llm-chat/composables/chat/useStreamingMessageSources.ts`（119-170行，渲染交接）
- `src/tools/llm-chat/composables/chat/useToolCallOrchestrator.ts`（73-470行）
- `src/tools/llm-chat/composables/chat/useTranslation.ts`
- `src/tools/llm-chat/stores/session/sessionGenerationManager.ts`（发送/重试/续写/排队，134-344行）
- `src/tools/llm-chat/stores/toolCallingStore.ts`（工具审批状态）、`src/services/decision-arbiter/`（自动审批仲裁）
- `src/tools/llm-chat/composables/features/useContextCompressor.ts`（45-660行）
- `src/tools/llm-chat/composables/features/useTranscriptionManager.ts`、`useAttachmentManager.ts`
- `src/tools/llm-chat/core/context-processors/session-loader.ts`（149-215行）、`transcription-processor.ts`、`asset-resolver.ts`、`variable-processor.ts`、`recall-processor.ts`（替换原 knowledge-processor）
- `src/tools/llm-chat/stores/contextPipelineStore.ts`、`core/pipeline/defaultProcessors.ts`
- `src/tools/llm-chat/stores/llmChatStore.ts`（排队/僵死修复 watch，150-240行）
- `src/tools/llm-chat/components/context-analyzer/*`（预览与视图）
- `packages/llm-core/src/output-tokens.ts`、`sampling-compatibility.ts`、`request-builder.ts`（输出预算与采样兼容）
- `src/llm-apis/adapters/deepseek/tools.ts`（DeepSeek 网页搜索/抓取独立端点）

## 附录 A：上下文压缩机制细节（专题附录）

### A.1 配置、触发条件与调用时机

上下文压缩是 **Agent 级配置**，字段位于 `LlmParameters.contextCompression`，默认配置在 `types/llm.ts:388-426`：

- 总开关默认关闭，自动触发默认开启，触发模式默认 `token`；
- Token 阈值 80000、消息阈值 50、最小历史数 15、最近消息保护数 10、单次最多压缩 20 条；
- 计数单位 `countUnit` 默认按消息条数，可改为按用户回合；两种单位各自记忆数量设置；
- 摘要节点默认使用 `system` 角色。

配置面板位于 Agent 参数编辑器的 `ContextCompressionConfigPanel.vue`（界面见 Chat UI 4.3）；当前实现已经移除了 Session 级压缩配置，生效优先级是"调用参数 > 当前选中 Agent 的配置 > 默认值"（`useContextCompressor.getEffectiveConfig()`，`useContextCompressor.ts:424-460`）。

自动判断分三步：先看总开关与自动触发开关，再看最小历史数门槛（`checkAndCompress`，`useContextCompressor.ts:493-509`）。涉及的字段为 `enabled`、`autoTrigger`、`minHistoryCount`。

触发模式由 `triggerMode` 决定，取值为 `token`、`count`、`both`。

`both` 表示 Token 或消息数任一超限即触发（OR 关系），比较符是严格的 `>`，等于阈值时不触发（`shouldCompress`，`useContextCompressor.ts:94-120`）。

Token 统计优先取 `llmChatStore.contextStats.totalTokenCount`，统计未就绪时回退为路径节点 `metadata.tokenCount` 之和（`calculateContextStats`，`useContextCompressor.ts:125-180`）。

自动检查点有两处：`useChatHandler.sendMessage()` 在创建新用户消息前调用一次，保证本轮请求能用刚生成的摘要；`useSingleNodeExecutor.execute()` 在助手节点完成后调用一次，工具循环中的单节点执行也经过后者。两处都捕获压缩错误，因此摘要请求失败不会阻断正常聊天。

输入框“更多”菜单提供手动压缩，角色未启用压缩时入口禁用。底层共享入口同样检查 `enabled`，所以直接调用也受总开关约束；手动模式只跳过自动触发开关和阈值（`useContextCompressor.ts:455-509`）。

手动压缩仍保留最近消息保护区；候选数不多于 `protectRecentCount` 时，返回“没有可压缩的消息”，不发出摘要请求。

### A.2 压缩范围、树结构与可逆性

压缩沿调用方传入的目标路径处理，未传时使用活动叶子；发送前检查显式传入该次发送父节点。它只在该路径内选取消息，隐藏分支保持原状。

候选筛选先去掉已启用摘要遮罩的消息，再排除系统消息和摘要节点。保留末尾保护区后，从最早的剩余消息起按配置数量取一批；旧消息继续保留在树中（`useContextCompressor.ts:519-568`）。

摘要由一次独立 LLM 请求生成。模型优先显式摘要配置，其次目标路径最近助手的请求绑定（优先保留虚拟渠道请求引用），最后回退当前 Agent；缺少有效绑定则报错。请求使用单条用户消息和独立摘要采样/输出预算（`useContextCompressor.ts:64-88,244-269,589-612`）。

成功后创建标记为压缩节点的普通树节点，插在该批最后一条被压缩消息后，把该消息原有子节点整体转挂到摘要下。元数据记录被遮罩 ID、原消息/Token 数、配置和时间，原树消息继续保留（`useContextCompressor.ts:280-416`）。

被遮罩消息若带 Provider 推理回放 artifact，摘要节点会标记 `reasoningStateStatus: "broken"` 并写警告：后续请求无法再回放已隐藏消息的推理状态（同文件 `:309-339`）。

请求上下文由 `session-loader.ts:105-153` 两遍回溯构建（第 2 节）。因此"压缩"准确说是**非破坏性上下文遮罩**。`CompressionMessage.vue` 允许用户直接编辑摘要、切换摘要角色、启用/禁用和删除；禁用压缩节点会让原消息重新进入上下文，删除则走会话管理 4.4 的特殊重挂逻辑。原消息一直存在于会话 JSON 和树图里，线性消息列表只是用半透明样式标记其已被压缩状态（渲染在渲染器笔记 1.2）。

压缩成功后会立即 `persistSessions()` 并刷新上下文 Token 统计（`useContextCompressor.ts:613-617`）。返回值里的 `savedTokenCount` 只是被遮罩节点记录的 Token 总和，**没有减去新摘要自身的 Token**（`useContextCompressor.ts:598-602,619-623`），所以它是"原内容 Token 数"，不是严格意义上的净节省量。

### A.3 压缩实现与仓库说明的差异

- `executeCompression()` 先定位本次压缩范围之前最近一个"已启用且未被遮罩"的摘要节点，把它作为 previousSummary 传给 generateSummary()；后者在有前情提要时改用续写模板，模板取自内置的 CONTINUE_CONTEXT_COMPRESSION_PROMPT 或用户配置的 continueSummaryPrompt。
- 新摘要创建时把旧摘要一并纳入 compressionNodes，即旧摘要随新压缩一起被隐藏，避免上下文中累积多个摘要；新摘要的 originalTokenCount 与 originalMessageCount 会继承旧摘要承载的历史统计（`useContextCompressor.ts:183-600`）。
- 仓库文档 `src/tools/llm-chat/docs/architecture/context-compression.md` 同步改写了对应段落。

注：旧摘要的定位只找"本次压缩范围之前最近"的一个，且摘要生成/隐藏链路为静态代码确认，未做运行验证。

### A.4 后台压缩的状态依赖错位

有效压缩配置仍从当前选中 Agent 合并，触发用 Token 总数又优先读取当前会话的全局统计；目标后台会话并行生成时，配置和阈值统计存在前台状态依赖。摘要模型与摘要 Token 计算则已优先使用目标路径最近助手绑定，缺少绑定时才回退 Agent，故不能把模型错位概括为必然行为。多会话误触发结果未运行复现（`useContextCompressor.ts:158-174,424-449,589-628`）。

### A.5 计数单位与压缩范围

`countUnit` 为 `user-turn` 时，压缩候选与"保护区/单次量"都按回合计算：一个回合从用户消息开始，包含其后的助手回复与工具结果，直到下一个用户消息为止；原生 tool-calling 的多条 tool 消息与 VCP 拆分消息都归入当前回合。两种单位分别记忆数量设置，切换单位不会重置另一套配置。该规则同时作用于触发阈值（`shouldCompress`）和实际压缩范围（`executeCompression`），因此同一配置在不同会话里可能因消息构成不同而命中原消息数量不同。
