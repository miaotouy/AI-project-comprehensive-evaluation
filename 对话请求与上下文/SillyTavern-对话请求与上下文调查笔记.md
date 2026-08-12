# SillyTavern 对话请求与上下文调查笔记

> 调查对象：`E:\works\git\SillyTavern`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8`（分支：`release`）
>
> 调查方式：直接阅读源码（`public/script.js` 的 `Generate()` 主链、正则引擎、slash command 执行器、群聊生成包装器、OpenAI 消息组装），逐段核对当前 HEAD 的执行顺序与分支
>
> 调查范围：一次生成任务的提交入口、历史筛选与上下文拼装顺序、token 预算与截断、provider 交接与流式事件链、完成/异常/停止/重试/续写的收口语义、群聊串行生成、外部能力（World Info、Data Bank、工具、正则、宏、Quick Reply）注入点；数据对象语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

SillyTavern 的一次生成由 `Generate()`（`public/script.js:4231`）统一入口驱动，slash command 可以在真正调用生成 API 之前整体劫持发送流程：

- 主链：`sendTextareaMessage()` → `Generate()` → 历史筛选（`is_system` 排除 + 工具 system 例外）→ 逐条消息正则/附件/标题处理 → 角色字段与 system prompt → World Info 扫描与注入 → 生成 interceptors → 按 API 类型拼 text completion 或 OpenAI messages → token 预算裁剪 → `generate_data` → 流式/非流式请求 → `saveReply`/流式收尾 → `saveChatConditional()`。
- **slash command 拦截点在生成函数最前面**：`Generate()` 在取输入之前执行 `processCommands()`（4251-4259），判定为打断时本次 Generate 直接短路，不发任何生成请求。
- **正则按用途分层**（`public/scripts/extensions/regex/engine.js:334-381`）：无标记脚本在生成后清洗（`cleanUpMessage`，结果写回 `chat[].mes` 持久化）与 prompt 组装两处都生效；`markdownOnly` 只影响显示；`promptOnly` 只在 prompt 组装时生效（本次已定位调用点：`Generate` 的 `coreChat` 映射，`public/script.js:4447`）。
- **宏替换不是一次性统一处理**：`substituteParams()` 在用户消息发送、首条消息渲染、user prompt bias、quiet prompt、正则替换等多个代码路径独立调用。
- Quick Reply 用 `eventSource.makeFirst` 抢占 `USER_MESSAGE_RENDERED`/`CHARACTER_MESSAGE_RENDERED` 事件，插在事件分发链最前面。
- 群聊"重新生成"与单聊"swipe"是两套机制：群聊靠 `extra.gen_id` 分组 + 物理删除尾部消息；群聊内多个成员串行生成，由 `generateGroupWrapper` 循环驱动。

## 系统边界与生成任务主链

```text
sendTextareaMessage()（script.js:1705；#send_but 经 SimpleMutex 进入，11099-11102）
  -> Generate()（script.js:4231）
      -> GENERATION_STARTED 事件（4240）
      -> processCommands()（3066-3074，调用点 4252）：以 "/" 开头则整段交给 slash command 执行并短路返回
      -> GENERATION_AFTER_COMMANDS（4262）；群聊分支转 generateGroupWrapper（4291-4319）
      -> 取输入框文本；regenerate 先 removeLastMessage（4337-4353）；getBiasStrings（4374）
      -> sendMessageAsUser / send_if_empty（4389-4399）
      -> 角色卡字段 + depth prompt（4401-4427）；首条问候语宏替换（4430-4432）
      -> coreChat 筛选：is_system 排除、tool_invocations 例外（4435-4440）
      -> 逐条正则（isPrompt）+ appendFileContent + 标题拼接 + reasoning 前缀（4442-4498）
      -> runGenerationInterceptors（4505-4511）-> Horde 调整/CFG 扣减（4516-4545）
      -> World Info 扫描与注入（4564-4622，getWorldInfoPrompt 4576）
      -> system/jailbreak/story string/chat inject（4627-4706）
      -> 角色转换 chat2[] / oaiMessages（4708-4777）
      -> token 预算：arrMes 循环回填 + checkPromptSize 递归裁剪（4814-5068）
      -> finalPrompt（5181）-> generate_data 按 API 分支（5190-5257）
      -> 流式 StreamingProcessor（5326-5388）/ 非流式 sendGenerationRequest（5390）
      -> saveReply 落定（5473-5476）/ 工具调用再入（5350-5378, 5482-5501）
      -> saveChatConditional()（5514）/ auto_swipe（5508-5511）/ triggerAutoContinue（5519）
```

边界：`chat[]` 与 JSONL 的数据语义在会话与消息管理；`StreamingProcessor` 的 DOM 更新、正则 `markdownOnly` 渲染层、宏第 0 条渲染特例在消息渲染器笔记；swipe 按钮、停止按钮、发送前配置等用户工作流在 Chat UI。

## 1. 提交入口、任务对象与状态机

- 入口：`sendTextareaMessage()`（`public/script.js:1705-1740`）在 `swipeState === NONE`、`!is_send_press`、无 slash command 执行中时继续；"继续生成"开关（`power_user.continue_on_send`）在空输入 + 最后一条是角色消息时把类型改成 `continue`（1722-1731）。发送按钮绑定 `SimpleMutex(sendTextareaMessage)` 串行化（11099-11102），防止连点并发。
- 任务对象：没有独立的任务/请求对象——生成状态就是模块级变量组合：`is_send_press`（602）加锁、`abortController`（460）、`streamingProcessor`（455）、`swipeState`、`chat_metadata.tainted`（4288 在非 dryRun 时置真）。事件 `GENERATION_STARTED`（4240）与 `GENERATION_AFTER_COMMANDS`（4262）成对，slash 短路时只发前者。
- 用户消息：`sendMessageAsUser()`（5815-5864）先正则（5816）再宏替换（5823）后 push 进 `chat`，发 `MESSAGE_SENT`/`USER_MESSAGE_RENDERED`（5858-5860）；bias 消息（只有 bias 无正文）改走 `sendSystemMessage`（4390-4393）。
- 回复消息：`saveReply()`（6583-6771）按类型分支：`normal` 新建消息、`swipe` 复用最后一条的 swipes、`append`/`continue`/`appendFinal` 追加正文；群聊消息额外写 `force_avatar`/`original_avatar`/`extra.gen_id`（6708-6717）。

## 2. 历史选择与上下文拼装顺序

按 `Generate()` 内的实际顺序：

1. **筛选**：`chat.filter(x => !x.is_system || (canUseTools && Array.isArray(x.extra?.tool_invocations)))`（4437）——隐藏消息（`is_system`）排除，工具调用 system 消息例外保留。
2. **逐条处理**：按消息类型取 `regex_placement.USER_INPUT`/`AI_OUTPUT` 跑 `getRegexedString(..., {isPrompt: true, depth})`（4444-4447）；`appendFileContent` 展开消息附件文件文本（4448）；`extra.append_title` 与媒体标题拼接（4450-4463）。
3. **reasoning**：从最新往回给每条消息前缀 reasoning（4472-4498，`regex_placement.REASONING` 跑正则），群聊只处理当前生成角色（4478）。
4. **字符字段**：`getCharacterCardFields()` 取 description/personality/scenario/examples/system/jailbreak 等（4401-4411）；depth prompt（角色/群聊）注入为 extension prompt（4414-4427）。
5. **World Info**：`chatForWI`（名称+正文的反向数组）→ `getWorldInfoPrompt(chat, this_max_context, ...)`（4565-4576）→ 扫描结果按 before/after/depth/example/outlet 注入 extension prompts（4605-4622）；`WORLD_INFO_ACTIVATED` 事件在非 dryRun 时发出（`world-info.js:900-903`）。
6. **系统提示**：text completion API 用 `power_user.sysprompt`（`substituteParams(system, {original: ...})` 或 `baseChatReplace`，4627-4638）；jailbreak 在继续生成时插到倒数第二条之前（4696-4704）。
7. **story string**：按 before/after anchor 与各字段模板渲染，`IN_CHAT` 位置时注入（4640-4676）；`doChatInject` 执行 chat 注入（4684-4687）。
8. **角色转换**：text completion 走 `formatMessageHistoryItem`（instruct 模式加首/末序列，4723-4757）；OpenAI 走 `setOpenAIMessages`（`public/scripts/openai.js:561-640`，处理 narrator→system、名称前缀策略、媒体、工具调用、reasoning 签名）。
9. **组合**：`getCombinedPrompt` 按  story string + examples + 聊天 + 最后一行（名字/quiet prompt/bias）拼出 `finalPrompt`（5073-5181）；期间发 `GENERATE_BEFORE_COMBINE_PROMPTS`（5175）与 `GENERATE_AFTER_COMBINE_PROMPTS`（5183-5185）事件，扩展可以替换整个 prompt。

## 3. 预算、截断、摘要与压缩

- **预算**：`getMaxPromptTokens()` = `getMaxContextTokens() - getMaxResponseTokens()`（5922-5928）；OpenAI 用 `oai_settings.openai_max_context - openai_max_tokens`（`itemized-prompts.js:181`）。
- **text completion 截断**：`arrMes` 从最新往回逐条累计 token，超预算停止（4814-4868），注入消息（`injectedIndices`）优先预分配（4820-4841）；示例消息在剩余预算内补（4898-4911）；`checkPromptSize()` 在拼好后仍超限时先丢示例再丢最旧消息、递归重试（5034-5060）。
- **OpenAI 截断**：`ChatCompletion` 类在 `prepareOpenAIMessages` 内设置 token 预算（`openai.js:1558`），`populateChatCompletion` 按预算装填，必选 prompt 超限抛 `TokenBudgetExceededError` 并提示"Raise your token limit"（1578-1587）。
- **World Info 预算**：`checkWorldInfo(chat, maxContext, ...)`（`world-info.js:4597`）按 `world_info_budget`/`budget_cap` 控制扫描与注入量。
- **摘要/记忆**：`extension_prompts['1_memory']`（记忆扩展输出）与 `2_floating_prompt`（作者注释）作为扩展 prompt 参与拼装并在 itemized 记录（5287-5288）；"记忆压缩/总结"是 memory 扩展的职责，本笔记只记录其注入位置（itemized prompt 记录点 `public/script.js:5287` 与 `getAllExtensionPrompts` 5285）。
- 截断不可逆：被裁剪的历史不会回填，也没有"重新生成时扩大预算"的机制。

## 4. Provider、模型与协议交接

- **协议 Adapter 的接管点**：`Generate` 内 `switch (main_api)`（5190-5257）按 Kobold/KoboldHorde/TextGen/Novel/OpenAI 分支构建 `generate_data`（`getKoboldGenerationData`/`getTextGenGenerationData`/`getNovelGenerationData`/`prepareOpenAIMessages`）。
- **发送**：流式 `sendStreamingRequest`（6088-6105）按 API 调 `sendOpenAIRequest`/`generateTextGenWithStreaming`/`generateNovelWithStreaming`/`generateKoboldWithStreaming`；非流式 `sendGenerationRequest`（6057-6079）OpenAI 走 `sendOpenAIRequest`，Horde 走 `generateHorde`，其余 `fetch(getGenerateUrl(main_api))`。
- **网络路径**：浏览器不直连外部 provider，而是打到 SillyTavern 服务端代理端点（`getGenerateUrl`，6113-6126，如 `/api/backends/text-completions/generate`；服务端 `src/endpoints/backends/text-completions.js:272` 再转发并透传流式响应）。abort 也经服务端（`text-completions.js:89` 转发 `/api/extra/abort`）。
- **模型/参数解析**：`main_api`/`oai_settings`/`kai_settings` 等模块级设置是事实源；服务端不参与 prompt 语义，只做代理转发。fallback/重试机制：本次在 text-completions 后端未找到重试逻辑（搜索 `retry` 无命中）；Horde 有 `adjustHordeGenerationParams` 的上下文/长度自适应（4516-4528）。

## 5. 流式事件、缓冲、节流与顺序

- **流式消费**：`StreamingProcessor`（3481+）持有生成器，`generate()` 逐段消费（5337）；`onProgressStreaming`（3584-3685）每段先 `cleanUpMessage`（含 stopping strings 截断与正则）再写 `chat[messageId].mes` 与 DOM，`swipe`/`continue` 类型同步回 `swipes[swipe_id]`（3646-3654）。
- **顺序保证**：文本按到达顺序追加，无并发缓冲队列；`stream_fade_in`/`streaming_fps` 是渲染侧节流（渲染器笔记）。
- **事件时机**：`MESSAGE_RECEIVED`/`CHARACTER_MESSAGE_RENDERED` 只在流结束（`finalizeIntermediaryMessage` 3740-3741）或错误收尾（`onErrorStreaming` 3768-3771，swipe/impersonate/continue 不发）emit 一次，不随 token 触发；`MESSAGE_SWIPED` 每次 swipe 动画后发（10255）。
- **interceptors**：`runGenerationInterceptors(chat, contextSize, abort, type)`（`public/scripts/extensions.js:2015-2040`）按 manifest 顺序执行全局函数，可 `abort(true)` 立即终止后续并在 `Generate` 内短路返回（4505-4511）。

## 6. 完成、异常、半截流与最终回写

- **流式完成**：`onFinishStreaming`（3749-3759）= `finalizeIntermediaryMessage`（swipes 收尾、`syncMesToSwipe`、`saveLogprobsForActiveMessage`、事件、可选解锁 UI）→ auto_swipe 判定 → `saveChatConditional()` → 提示音。
- **非流式完成**：`onSuccess`（5402-5524）`extractMessageFromData` → `cleanUpMessage` → `saveReply`（continue 类型用 `appendFinal`）→ `parseAndSaveLogprobs` → 工具调用分支（5482-5501）→ `saveChatConditional()`（5514）。
- **异常**：`onError`（5531-5541）toast 错误 + `unblockGeneration` + 置空 `streamingProcessor` 后重抛；流式错误 `onErrorStreaming` abort 并保留半截消息在 `chat[]`（不发事件时消息仍可见）。
- **半截流**：手动停止（`stopGeneration`，5548-5559）调 `streamingProcessor.onStopStreaming()` + `abortController.abort()`，不保存；`beforeunload` 只 abort（12401-12407）。半截消息是否落盘：未停止的流在 `onFinishStreaming` 前不落盘。
- **工具调用收尾**：`finalizeIntermediaryMessage({unlockUI: false})`（5357）先落定消息但不解锁输入框，`streamingProcessor = null` 延后到工具结果处理后（5369/5373），随后 `depth+1` 递归 `Generate('normal', ...)` 继续（5376）——"流式结束"与"生成流程结束"是两个时间点。

## 7. 停止、重试、续写与重新生成

| 机制 | 触发者 | 执行层语义 |
|---|---|---|
| 停止 | `stopGeneration()`（5548-5559）；`.mes_stop` 按钮（12070-12072）、Action Loader toast、Escape（12280-12287） | `streamingProcessor.onStopStreaming()`（保留下半截内存消息）+ `abortController.abort()`（网络中止，经服务端转发） |
| 重新生成 | 菜单 `option_regenerate`（11567-11580）、`/regenerate`（`slash-commands.js:1530`）、Ctrl+Enter | 单聊 `Generate('regenerate')`：`removeLastMessage` 删尾再生成；群聊 `regenerateGroup` 按 `gen_id` 删尾（`group-chats.js:167-188`） |
| 续写 | 菜单 `option_continue`（11586-11599）、`/continue`（`slash-commands.js:1489`）、Alt+Enter、auto_continue（`triggerAutoContinue` 5724-5733） | `Generate('continue')`：最后一条留在上下文里，`continue_mag` 记前缀，`saveReply` append |
| swipe 生成新候选 | swipe 越界 REGENERATE（10250-10260） | `Generate('swipe')`：`coreChat.pop()` 去掉最后一条（4438-4440）再生成，`saveReply` 的 swipe 分支写候选 |
| 手动重试 | 无 `/retry` 命令；错误后用户重新发送/重新生成 | 无自动重试（本次未找到后端重试逻辑） |

## 8. 队列、多会话并发与后台生成

- **同一会话串行**：`is_send_press` 单锁 + 发送按钮 `SimpleMutex`；`swipeState` 禁止发送/swipe 交错；编辑态（`swipeState === EDITING`）拒绝发送与继续（1707-1711, 11587-11590）。
- **群聊内串行**：`generateGroupWrapper`（`group-chats.js:945-1092`）`is_group_generating` 重入保护（958-960），按激活策略（NATURAL/LIST/POOLED/MANUAL + swipe/continue/impersonate/quiet 特例，1002-1031）选出成员，循环 `setCharacterId` → `GROUP_MEMBER_DRAFTED`（1059）→ `Generate()` → 可能的 auto-continue 循环（1067-1070），全部完成才解锁（1077-1089）。`group_generation_id = Date.now()`（988）即该批次的 `gen_id`。
- **后台生成**：生成期间输入框保持可用（`is_send_press` 只挡重复发送），但同一聊天的 swipe/重新生成被禁；群聊 auto mode 由 `setAutoModeWorker`/`groupChatAutoModeWorker` 在核心代码内定时驱动（`group-chats.js:144, 1398`）。
- **不同会话**：一次只显示一个聊天；没有"多会话并行生成"的 UI 概念（欢迎屏/后台通知均无，见 Chat UI 笔记）。

## 9. 外部能力注入点

| 能力 | 注入点 |
|---|---|
| World Info | `getWorldInfoPrompt` 调用点 `public/script.js:4576`；`WORLD_INFO_ACTIVATED` 事件 `world-info.js:900-903` |
| 记忆/作者注释/上下文压缩 | 扩展 prompt 槽 `1_memory`/`2_floating_prompt`（`public/script.js:5287-5288`），扩展自身在 `GENERATION_AFTER_COMMANDS` 等事件钩子更新 |
| 向量检索（chat + Data Bank） | 扩展 prompt 槽 `3_vectors`/`4_vectors_data_bank`（5289-5291）；Data Bank 经 vectors 扩展摄取与检索注入（见会话与消息管理笔记 8） |
| 工具 | `ToolManager.isToolCallingSupported`/`canPerformToolCalls` 决定是否启用（4435-4436）；结果经 `ToolManager.saveFunctionToolInvocations` 写为 `extra.tool_invocations` 并递归 `Generate`（5375-5376） |
| 正则 | 三处：prompt 组装（4447, isPrompt）、生成后清洗（`cleanUpMessage` 6422）、渲染（`messageFormatting` 1809-1813, isMarkdown）；`regex_placement` 枚举 `engine.js:281-292` |
| 宏 | `substituteParams`（定义 2922）调用点：用户消息（5823）、首条问候语（4431）、user prompt bias（1780, 6401）、quiet prompt（4324）、正则替换（`engine.js:444`） |
| Quick Reply | `eventSource.makeFirst(USER_MESSAGE_RENDERED/CHARACTER_MESSAGE_RENDERED)`（`extensions/quick-reply/index.js:282, 292`），还有 `CHAT_CHANGED`（275）、`WORLD_INFO_ACTIVATED`（302）、`GENERATION_AFTER_COMMANDS`（321）等钩子 |
| 附件文本 | `appendFileContent`（`public/script.js:4448` 调用，实现在 `chats.js:508`） |

`makeFirst` 意味着 Quick Reply 的自动化钩子在其它同事件监听器之前执行：若自动回复规则命中，可能在其它扩展处理完当前消息之前就发起下一轮生成（自动回复实际请求仍走 `Generate`，遵守同一把锁）。

## 10. 退出恢复、日志与已确认边界

- **退出**：`beforeunload` 中止流式但不保存（12401-12407）；流式中途消息不持久化（见 6）。
- **可观测性**：`power_user.console_log_prompts` 打印最终 prompt（5271-5273）；itemized prompts（每次生成的完整 prompt 与分项 token 数）写入 IndexedDB（5280-5322，见会话与消息管理笔记 2.1），供消息上的 Prompt 按钮查看；`GENERATION_STARTED/STOPPED/ENDED` 事件可供扩展记录。
- **已确认边界**：一次请求的上下文以 `finalPrompt`/`generate_data.prompt` 为准——设置面板或扩展 prompt 中存在某字段不等于本次请求携带（`GENERATE_AFTER_COMBINE_PROMPTS` 可整体替换）；文本 completion 与 OpenAI 两条拼装链在截断与注入顺序上实现完全不同；服务端只做代理，不持有会话状态。

## 11. 未验证事项

- OpenAI 路径 `ChatCompletion`/`populateChatCompletion` 内部按什么粒度（消息 vs part vs system prompt）裁剪，只核实了预算入口与超限报错，未逐行核对装填算法。
- 各后端（Novel/Kobold/TextGen）的停止序列、半截流行为与错误形态未逐一实测。
- Horde 的 `adjustHordeGenerationParams` 细节（上下文/长度自适应计算）未展开。
- auto_swipe 过滤（`generatedTextFiltered`）与 auto_continue 判定（`shouldAutoContinue`）的阈值逻辑未逐行核对。
- 工具调用循环的递归上限 `RECURSE_LIMIT` 之外的服务端超时/中断行为未验证。

## 12. 关键源码索引

- `public/script.js`：`Generate()`（4231-5542）；`processCommands`（3066-3074）；`sendTextareaMessage`（1705-1740）；`sendMessageAsUser`（5815-5864）；`saveReply`（6583-6771）；`cleanUpMessage`（6383-6534）；`stopGeneration`（5548-5559）；`unblockGeneration`（5634-5645）；`sendStreamingRequest`/`sendGenerationRequest`（6057-6105）；`getMaxPromptTokens`（5922-5928）；`StreamingProcessor`（3481-3853）
- `public/scripts/extensions/regex/engine.js`：`getRegexedString`（334-381）；`runRegexScript`（391-448）；`regex_placement`（281-292）
- `public/scripts/openai.js`：`setOpenAIMessages`（561-640）；`prepareOpenAIMessages`（1533-1615）
- `public/scripts/world-info.js`：`getWorldInfoPrompt`（892-915）；`checkWorldInfo`（4597）
- `public/scripts/extensions.js`：`runGenerationInterceptors`（2015-2040）
- `public/scripts/extensions/quick-reply/index.js`：事件绑定（257-321）
- `public/scripts/group-chats.js`：`regenerateGroup`（167-188）；`generateGroupWrapper`（945-1092）
- `public/scripts/slash-commands.js`：`/continue` `/regenerate` `/swipe` 等生成命令（1489-1563）
