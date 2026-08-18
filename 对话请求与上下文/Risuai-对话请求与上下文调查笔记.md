# Risuai 对话请求与上下文调查笔记

> 调查对象：`https://github.com/kwaroran/Risuai`
>
> 调查更新日期：2026-08-17
>
> 代码快照：`0551d283faeba6e73899b01dd85ea38307b24699`（分支：`main`）
>
> 调查方式：直接阅读源码（`src/ts/process/index.svelte.ts` 的 `sendChat` 全链、`request/` 各 Provider 的流式实现与工具循环、`memory/` 四个记忆引擎、`globalApi.svelte.ts` 网络层与持久化循环、`src-tauri` 的请求命令），静态追踪调用链与状态分支；未运行应用
>
> 调查范围：一次生成任务的提交入口、任务对象与状态机、历史选择与上下文拼装顺序、token 预算与记忆压缩、Provider 交接与协议适配、流式事件链与节流、完成/异常/半截流收口、停止/重试/续写/重新生成、群聊串行与并发、外部能力注入点、退出恢复与可观测性；消息与会话的 schema、Composer 与按钮工作流、流式文本的 DOM 渲染分别归会话与消息管理、Chat UI、消息渲染器类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- 一次生成由 `sendChat(chatProcessIndex, arg)`（`src/ts/process/index.svelte.ts:99`）统一驱动。没有独立任务对象：运行状态是全局 store 与调用方参数的组合（`doingChat` 锁、`chatProcessStage` 阶段进度、UI 持有的中止信号），任务的权威记录是写回消息的 `generationInfo`——含 `generationId`、输入/输出 token 估算与四个阶段的耗时。
- 上下文拼装分两遍：先用"提示词模板"卡片（或旧式 `formatingOrder` 分组）逐项预检 token 并装入分组桶，再按同一顺序把各桶拼成最终消息数组；无模板时走固定分组顺序。最终请求以 `requestChatData` 收到的数组为准，可用 DevTool/快捷键的 preview 模式核对。
- 预算以全局 `maxContext` 为上限：无记忆引擎时从消息数组头部整条删除；启用记忆后由所选引擎（SupaMemory / HypaMemoryV2 / HypaMemoryV3 / HanuraiMemory）各自截断或摘要，压缩不可逆；拼装后还有一次只清空可移除消息的 token 重检。
- Provider 交接点是 `requestChatData` → `requestChatDataMain` 的 `LLMFormat` 分发（`src/ts/process/request/request.ts:484-528`），此前先做 `reformater` 角色兼容；OpenAI/Claude/Gemini 各自解析 SSE 并把**累计全文**放进 key 为 `0` 的流式块，消费端每次整段替换消息文本。
- 流式占位消息在请求前就已写入会话（`chatId = generationId`），持久化由全局保存循环（500ms 防抖 + 全库编码写盘）持续进行，因此半截消息会随保存落盘，与"流结束才落定"的实现不同。
- 停止只发生在本地消费层：UI 的 `AbortController` 会中止 fetch 与流 reader，但 Tauri 桌面端的 `streamed_fetch`（`src-tauri/src/main.rs:433`）没有取消命令，网络请求会继续到服务端结束或 240 秒超时。
- 并发粒度是"全局单任务"：`doingChat` 锁与 UI 的 `$doingChat` 检查直接拒绝新的发送，不排队、不替换当前任务；群聊成员由 `sendChat` 内的循环按顺序串行生成。

## 系统边界与生成任务主链

```text
DefaultChatScreen.svelte sendMain()（144-216；用户消息 push + editinput 脚本）
  -> sendChatMain()（305-329；新建 AbortController，sendChat(-1, {signal, continue}))
  -> sendChat()（index.svelte.ts:99）
      -> doingChat 锁（212-219）；群聊则按顺序循环 sendChat(i)（295-336）
      -> 提示词模板/分组 token 预检（676-829）
      -> 角色字段、lorebook、persona、作者注释等分组建桶（410-611）
      -> 逐条消息 editprocess 处理（900-1053）；depth lorebook（1056-1066）
      -> 记忆引擎 stage2（1068-1140）或无记忆时的头部截断（1141-1154）
      -> 触发脚本 start 钩子（888-898）
      -> 模板顺序拼装 formated（1271-1468）；角色 depth_prompt（1484-1491）；Lua editRequest（1493）
      -> token 重检（1500-1523）；估算输出预算（1526-1529）；generationInfo（1530-1545）
      -> requestChatData（1554-1567）→ 回退/重试包装（request.ts:205-346）→ LLMFormat 分发（484-528）
      -> Provider 流（SSE/WS）→ getTranStream/wrapToolStream 等 → streaming 块
      -> sendChat 消费 reader（1591-1753）：占位消息已存在，逐块 processScriptFull('editoutput') 写回
      -> 完成收尾：rerolls 候选（1759）、output 触发脚本（1763）、inlay/插件监听/TTS（1772-1793）
      -> autoContinue / resendChat 递归（1885-1945）；情感与图片生成副链（1991-2190）
```

边界：`Message`/`Chat` 数据对象与保存编码属于会话与消息管理；Composer、停止按钮、发送前配置与消息操作工作流属于 Chat UI；流式文本的 DOM 更新与滚动属于消息渲染器；MCP 客户端内部机制属于 Agent 工具；模型目录与凭据解析属于 LLM 渠道管理。本笔记只记录交接点与调用顺序。

## 1. 提交入口、任务对象与状态机

- **发送入口**：`DefaultChatScreen.svelte` 的 `sendMain()`（144-216）在 `$doingChat` 为真时直接返回；输入以 `/` 开头时先走 `processMultiCommand`（`command.ts:11`），返回非 false 则短路本次发送。
- **消息写入与调用**：用户消息 push 进当前聊天（角色房先过 `editinput` 正则脚本），随后 `sendChatMain` 新建中止控制器并调 `sendChat(-1, {signal, continue})`（305-329）。
- 命令入口：`/multisend` 等命令可以在命令链内直接 `await sendChat(-1)` 触发生成（`command.ts:163-181`）。
- 状态机：模块级 `doingChat` store 是唯一锁，`sendChat` 开头对 `chatProcessIndex === -1` 的重复调用直接返回 false（212-219）；`chatProcessStage` 0-4 表达阶段进度（0 准备、1 上下文构建、2 记忆、3 请求、4 收尾），UI 用 `chat-process-stage-*` 样式类展示。导出的 `abortChat` store 在整个代码库中从未被 set（仅声明），实际停止走调用方自己的 `AbortController`。
- 任务对象：`generationId = v4()` 同时用作消息的 `chatId`；`generationInfo` 记录模型串、输入/输出 token 估算、`maxContext` 与四个阶段耗时（1530-1545），完成后写回最后一条消息（2202-2205）。没有独立的取消令牌、任务注册表或队列对象。
- 群聊：`chatProcessIndex === -1` 且房型为 group 时，按排序后的成员列表循环 `await sendChat(i)`，任一成员返回 false 则整批停止（295-336）；成员调用因索引非负可绕过锁。

## 2. 历史选择与上下文拼装顺序

按 `sendChat` 的实际执行顺序：

1. **消息选择**：`makeMs` 从后往前收集，跳过 `disabled === true` 的消息，遇到 `disabled === 'allBefore'` 则清空其之前的全部消息（849-864）。
2. **开场白**：非群聊且未重置时取 `firstMessage` 或 `alternateGreetings[fmIndex]`，经 `editprocess` 处理作为 assistant 消息加入（868-884）。
3. **系统桶**：main prompt（角色 `systemPrompt` 替换 `{{original}}` 后并入全局 main prompt）、jailbreak（开关控制）、全局注释、作者注释（聊天 note 或默认值）；chain-of-thought 的思考指令进 postEverything 桶（410-464）。
4. **角色字段**：description（desc + 嵌入补充信息 `additionalInformations` + personality + scenario，466-496）；群聊再追加"只扮演当前角色"指令。
5. **lorebook 分流**：`loadLoreBookV3Prompt` 扫描的激活条目按位置分流——无位置的进 lorebook 桶，before/after_desc 与 personality/scenario 位置的围住描述消息，`depth` 为 0 的进 postEverything，assistant 角色的延后处理（498-611）。
6. **位置引用**：条目里的 `{{position::}}` 引用在注入时逐层解析，最多嵌套 5 层（500-527）。
7. **persona 与视图指令**：`personaPrompt` 开关、inlayViewScreen 的 emotion/imggen 指令进 postEverything（560-580）。
8. **示例与开场占位**：`exampleMessage` 生成示例对，随后加入 `[Start a new chat]` 占位（novelai 与 trimStartNewChat 除外）（831-845）。
9. **逐条消息处理**：历史消息逐条做 `editprocess`（正则脚本 + Lua `editInput` + 宏），提取 inlay 附件、思维块、`{{asset_prompt::}}` 图片；群聊消息按 `groupTemplate` 包装并依 `groupOtherBotRole` 改角色（900-1053）。
10. **depth lorebook 与记忆**：`depth > 0` / `reverse_depth` 条目按深度插入历史；随后进入记忆引擎阶段（1056-1140）。
11. **收尾桶**：无模板时把最后一条消息拆入末尾桶（1164-1167）；记忆消息在模板含 memory 卡时替换为空 system（由模板位置注入），否则包上 `<Previous Conversation>` 标签（1169-1186）；`start` 触发脚本的附加提示按 start/historyend/promptend 三位置插入（1197-1216）；续写模式追加续写指令（1228-1233）。
12. **拼装**：有模板时按卡片类型顺序 `pushPrompts` 出最终数组，相邻同角色 system 消息合并（1235-1258）；无模板时按 `formatingOrder` 分组顺序。卡片顺序为：

    ```
    persona → description → authornote → lorebook → postEverything → plain/jailbreak/cot → chatML → chat → memory → cache
    ```

    `chat` 卡的 rangeStart/rangeEnd 决定历史范围、`sendChatAsSystem` 时整段转 system（1383-1426）；自动缓存点在 chat 卡后标记最近 3 条 user 消息（1413-1426）。随后插入角色 depth_prompt、跑 Lua `editRequest` 钩子（1484-1497），才进入请求层。

## 3. 预算、截断、摘要与压缩

- **预算来源**：唯一预算来自全局 `maxContext`；`currentTokens` 从 `maxResponse + 50` 起算，逐条累加 `ChatTokenizer.tokenizeChat`（每条附加 3 或 5 个 token，另计名字与多模态折算，`src/ts/tokenizer.ts:412-487`）。
- **输出预算**：在请求前估算为 `maxResponse`，超上限时压到 `maxContext - inputTokens`（1526-1529）。
- **无记忆截断**：预检与逐条构建期间只累计不裁剪；stage 2 之后 `while (currentTokens > maxContextTokens)` 从数组头部整条删除（1141-1154），全删仍超限则报错中止。
- **记忆引擎选择**：只有 `nowChatroom.supaMemory` 且任一引擎开关（`supaModelType !== 'none'` / `hanuraiEnable` / `hypav2` / `hypaV3`）开启时进入 stage 2，优先级 Hanurai → HypaV2 → HypaV3 → SupaMemory（1068-1140）。
  - SupaMemory（`memory/supaMemory.ts:12`）：先裁到上次记忆点 `lastId`；超预算后按 `maxContext/3`（上限 `maxSupaChunkSize`）分块调用总结模型，块过大时按 0.7 缩小；旧记忆超过 4 段先压缩（25-135, 286-376）。结果作为 system 消息 unshift 到头部（memo 为 `supaMemory`/`hypaMemory`），写回 `room.supaMemoryData`（`lastId + '\n' + 摘要`，hypa 模式为 JSON），总结子请求走 `'memory'` 模式、非流式（378-427）。
  - HypaMemoryV2（`memory/hypav2.ts:335`）：从上次摘要覆盖点继续，逐批摘要并保留最后 4 条消息，摘要分块存向量，按比例预留记忆 token。
  - HypaMemoryV3 预算（`memory/hypav3.ts:118`）：先按 `memoryTokensRatio` 预留记忆预算；超预算时从摘要起点分批取 `maxChatsPerSummary` 条（跳过示例、空消息、可配置的 user 消息），直到 `queryChatCount` 下限或目标线 `maxContext * (1 - extraSummarizationRatio)`；摘要经限速器（subModel 按并发与每分钟上限，本地模型串行）完成后写入 `room.hypaV3Data`（118-466）。
  - HypaMemoryV3 注入：按 important → recent → similar（嵌入检索）→ random 四路选择填充预留预算，最终以 `<Past Events Summary>` XML 块作为头部 system 消息（877-935）。
  - HanuraiMemory（`memory/hanuraiMemory.ts:9`）：对历史做嵌入检索取高相关片段，同时从头部弹出直到预算内，检索结果作为 system 消息注入。
- **最终重检**：拼装后 `inputTokens > maxContext` 时从头扫描，只清空 `removable` 消息的内容再过滤（1500-1523）；记忆注入的消息不可移除。压缩不可逆，不会回填。
- **记忆数据落点**：无记忆路径下 `currentChat.lastMemory` 记录保留的最早消息 chatId（1153）；各引擎数据存于 `Chat` 的 `supaMemoryData`/`hypaV2Data`/`hypaV3Data` 字段（`src/ts/storage/database.svelte.ts:1823-1834`）。

## 4. Provider、模型与协议交接

- **请求包装**：`requestChatData(arg, model, abortSignal)`（`request/request.ts:205`）先克隆并 `risuUnescape` 输入，随后进入"回退模型 × 重试"双层循环：`fallbackModels[model]` 列表末尾追加空串作为主模型尝试（217-228）。
- **尝试前钩子**：每次尝试先跑插件 `replacerbeforeRequest` 与 `request` 触发脚本（可改写 formated，247-265），再调 `requestChatDataMain`（268-272）。
- **失败分类**：同模型按 `requestRetrys`（默认 2）重试；服务端超载（`failByServerError`）时 sleep 1 秒且 `antiServerOverloads` 令重试计数减半；`banCharacterset` 脚本集命中则整段结果重试；空白结果且开 `fallbackWhenBlankResponse` 时切下一个回退模型（291-337）。
- **模型解析**：`requestChatDataMain`（435-534）按 mode 选模型——`'model'` 用主模型，其余（memory/emotion/translate/submodel 等）用子模型，`seperateModelsForAxModels` 开启时每个 mode 可单独指定；`reverse_proxy`/`xcustom:::` 在此注入自定义 URL 与 key。
- **角色兼容**：`reformater`（348-432）按模型能力 flags 处理——无完整 system 支持时折叠或改写 system、要求角色交替时合并连续同角色消息、要求以 user 开头时补占位。
- **协议分发**：按 `LLMFormat` 枚举 switch 到各 Provider 实现（484-528）：OpenAI-compatible 与 Mistral 走 `requestOpenAI`，Responses API 走 `requestOpenAIResponseAPI`，Anthropic/Bedrock 走 `requestClaude`，Gemini 走 `requestGoogleCloudVertex`；另有 NovelAI、Ooba、Ollama、Kobold、Horde、Cohere、WebLLM、插件与 Echo 等分支，每个实现自行拼协议 body、解析端点并决定流式或整包。
- **网络路由**：所有 Provider 通过 `globalFetch`/`fetchNative`（`src/ts/globalApi.svelte.ts:681/1713`）发出——浏览器环境默认经服务端代理（`risu-header`/`risu-url` 头），Tauri 桌面走 `invoke('streamed_fetch')`（`src-tauri/src/main.rs:433`，reqwest 流式转发，默认 240 秒超时），节点自托管有独立代理通道。
- **超时与日志**：`buildTimeoutSignal` 给请求套可选超时；请求携带 `chatId` 供 fetch 日志关联。
- 与 SillyTavern 相比，Risuai 各 Provider 是独立实现而非统一 Adapter 接口，消息构建全部在 TS 侧完成，Rust 端只做字节转发、不解析 SSE。

## 5. 流式事件、缓冲、节流与顺序

- **OpenAI 流**（`request/openAI/requests.ts`）：`fetchNative` 以 `interceptor: 'openai_streaming'` 拿到原始 SSE body，`getTranStream`（972-1136）按 `data: ` 行解析并累积文本。
- **块契约**：每个输出块是**累计全文**的 `{"0": text}`（多选生成按 choice index 分键，并附带累积的 `__tool_calls`）；`[DONE]` 时一次性 flush。
- **流内后处理**：reasoning 字段包成 `<Thoughts>`，开启 `extractJson` 时在结束时提取 JSON 字段。
- **Anthropic 流**（`request/anthropic.ts:899-1051`）：同样解析 SSE 事件，把 text/thinking/redacted_thinking 增量拼成 `<Thoughts>` 包裹的累计文本；遇到 `overload` 错误事件且开启 `antiServerOverloads` 时自动重连续流（959-1020）。
- **Claude Batch**：开启批量模式时提交 `batches` 端点后轮询状态，把最终结果包装成单个流式块；中止会先调用批量取消端点（615-885）。
- **Gemini 流**：`wrapToolStream`（`request/google.ts:1069-1309`）与 OpenAI 同构，另把思维与签名（`__thoughts`/`__sign_text`）拼入文本。
- **消费端占位与续写**：占位消息在读取前已 push（空 data），续写时改为取上一条文本做前缀（1591-1610）。
- **消费循环**：循环 `reader.read()`，每块取 `firstChunkKey` 的累计全文，经 `processScriptFull(..., 'editoutput')`（正则 + Lua `editOutput` + 宏）后整体写回 `message[msgIndex].data` 并 `reloadKeys += 1` 触发渲染；`removeIncompleteResponse` 时按标点截断半句（1687-1753）。
- **节流**：`streamingDisplayOptimizationMode` 分 off/balanced/strong 三档——balanced 与 strong 用 125ms 定时器加 `requestAnimationFrame` 把多个块合并为一次写回，strong 还把后处理推迟到流结束（1612-1681）；消费本身是单 reader 顺序执行，无并发。
- **事件时机**：流结束后才依次执行 `output` 触发脚本、inlay 屏幕、插件 `chatOutput` 监听器与 TTS（1761-1793），不随 token 触发。

## 6. 完成、异常、半截流与最终回写

- **流式完成**：读完后置 `isStreaming = false`，把最后一个块的**全部候选值**交给 `addRerolls`（多选/多生成候选的回退切换源，`prereroll.ts:26`）（1748-1759）。
- **收尾链**：`runCurrentChatFunction` 把最新消息重新做一次宏解析 → `output` 触发脚本（可 `sendAIprompt` 触发整轮重发）→ inlay 屏幕（含异步生成）→ 插件 chatOutput 监听 → 可选 TTS（1761-1793）。
- **非流式完成**：`success`/`multiline` 结果逐条写入消息（续写时合并进上一条），同样过 editoutput 与 inlay（1795-1883）；multiline 的多条都进 rerolls 候选。
- **异常**：`req.type === 'fail'` 时 `throwError`——默认弹错误框；开启 `inlayErrorResponse` 时把 `risuerror` 代码块追加到上一条角色消息或新建成错误消息（159-210）。流式读取抛错（非中止）沿调用链冒泡，由 UI 的 try/catch 弹出。
- **半截流**：中止（signal 或 reader 异常）后返回 false，半截文本连同 `generationInfo` 保留在消息中；流式期间的消息文本已经过保存循环落盘。这里没有"流结束后一次性落定"的阶段，也没有 `beforeunload` 时的流中止逻辑（见第 10 节）。
- **自动续写**：完成后 token 数低于 `autoContinueMinTokens`，或非标点结尾且开启 `autoContinueChat` 时，以 `continue: true` 递归 `sendChat`（1885-1904）。
- **副链请求**：IGP 提示（`igpPrompt` 非空）在主请求后追加一次 `'emotion'` 模式的子请求并把结果拼到末条消息（1906-1916）；情感视图（嵌入相似度或 token bias 两条实现）与图片生成（`imggen` 走 stableDiff）都在主链收尾后执行（1991-2190）。

## 7. 停止、重试、续写与重新生成

| 机制 | 触发者 | 执行层语义 |
|---|---|---|
| 停止 | 停止按钮 `onclick={abortChat}`（DefaultChatScreen.svelte:331, 662） | 调用方 `AbortController.abort()` → `sendChat` 内的 `reader.cancel()`（1682-1686）与 fetch signal；返回 false，半截消息保留；桌面端网络层不取消（见第 10 节） |
| 自动重试 | `requestChatData` 双层循环 | `requestRetrys`(2) 次同模型重试、`banCharacterset` 结果重试、`failByServerError` 慢重试、`fallbackModels` 模型回退（request.ts:222-339） |
| 续写 | 发送按钮的续写分支 `sendMain(true)`；autoContinue | 最后一条角色消息留在上下文，追加 `[Continue the last response]`；流式以原文本为前缀，非流式 append |
| 重新生成 | 消息菜单 reroll（DefaultChatScreen.svelte:218-271） | 弹出末尾消息到最近 user 边界（同角色最多回退 2 条）后重新 `sendChatMain()`；成功后新结果进 `rerolls` 数组；`unReroll` 用 `prereroll.ts` 的 `Prereroll`/`PreUnreroll` 按 generationId 恢复旧文本（273-301），不重新请求 |
| 多候选 | 多选生成 `genTime > 1`（仅 gpt 系、非续写） | 非流式返回 `multiline` 多条消息；流式时最后一块的多 choice 值进 rerolls 候选（request.ts:464） |

手动"重试"没有独立命令——错误后由用户重新发送或走上述机制。触发脚本的 `stopSending` 效果（`start` 钩子返回，index.svelte.ts:894-897）与 UI 停止是不同层级。

## 8. 队列、多会话并发与后台生成

- **串行粒度是全局的**：`doingChat` 锁加 UI `$doingChat` 检查，生成期间新的发送直接被拒——不排队、不替换当前任务；同一聊天内也没有 swipe 或队列概念。重新生成、续写与发送共用同一把锁。
- **群聊串行**：成员按 talkness 权重与最后消息单词匹配排序（`group.ts:52` 的 `groupOrder`，排除最后发言者，随机兜底），`sendChat` 内循环逐个 `await` 生成；任一成员失败即终止整批。
- **后台生成**：没有独立后台任务系统。三个相邻机制：输入栏自动模式 `runAutoMode` 在 UI 层循环调用 `sendChatMain`（DefaultChatScreen.svelte:337-348）；建议功能在 `doingChat` 变 false 时用 subModel 发起非流式子请求、生成开始时取消（Suggestion.svelte:126-133）；DevTool 的 autopilot 循环逐条发消息并在间隙手动重置锁（DevTool.svelte:217-237）。
- **静态观察**：`/multisend` 命令在命令链内逐条 `await sendChat(-1)`（command.ts:163-181），按当前代码第二次调用会撞上 `doingChat` 锁直接返回 false，且命令路径不复位锁；未运行验证。

## 9. Agent、工具、知识库与附件注入点

| 能力 | 注入点 |
|---|---|
| 工具目录 | `requestChatData` 开头 `getTools()` → `getMCPTools()`（`mcp/mcp.ts:231-275`），构建期就绪；`body.tools`（OpenAI）/`tools`（Anthropic）/`functionDeclarations`（Gemini）随请求携带 |
| 工具执行 | 在各 Provider 流包装器内联完成：OpenAI 的 `wrapToolStream`（requests.ts:1138-1318）在流结束时执行工具、把结果追加入消息并重新请求续流；Anthropic 在响应递归 `requestClaudeHTTP`（anthropic.ts:1088-1166）；Gemini 同构（google.ts:1110-1276） |
| 工具记录 | `rememberToolUsage` 把调用记录编码进输出，`simplifiedToolUse` 只保留工具码 |
| 知识库 | `loadLoreBookV3Prompt`（lorebook.svelte.ts:75）按 scanDepth、正则/全词匹配、token 预算（`loreBookToken` 默认 800）扫描角色/聊天/模块三层词条，激活结果由 sendChat 按位置注入（见第 2 节第 5 条） |
| 记忆 | stage 2 引擎输出（见第 3 节），随 `unformated` 进入拼装，记忆消息不可移除 |
| 附件 | 消息里的 `{{inlayed::}}`/`{{asset_prompt::}}` 占位在逐条处理时替换为多模态 base64（模型无图像输入时改用本地 caption 模型 `runImageEmbedding`），视频/音频只在第一条生效（index.svelte.ts:920-1037） |
| 嵌入补充 | `additionalInformations`（embedding/addinfo.ts:5）追加在角色描述之后（469-473） |
| 触发脚本 | `start`（可追加提示/停止发送）、`request`（请求前改写 formated，非群聊）、`output`（可触发整轮重发）、Lua `editRequest` 改写最终数组、正则脚本四模式（editinput/editoutput/editprocess/editdisplay） |
| 翻译 | `translator.ts:553` 以 `'translate'` 模式、非流式子请求调用 `requestChatData`（子模型 + 预设提示） |
| 建议 | Suggestion 组件以 `'submodel'` 模式发起非流式建议请求 |

## 10. 退出恢复、日志与已确认边界

- **退出**：Web 端 `beforeunload` 只阻止离开页面（`src/preload.ts:16`），不中止生成；没有页面隐藏或关闭时的取消逻辑。桌面端关闭窗口时，`streamed_fetch` 请求无取消通道，服务端请求继续到超时或完成（`src-tauri/src/main.rs:433-564`），但事件消费者已随窗口销毁，后续数据不会写入任何会话。
- **持久化**：`saveDb`（`src/ts/globalApi.svelte.ts:292-486`）监听 `DBState` 变化，任何会话消息改动经 500ms 防抖触发整库编码（RisuSaveEncoder）写盘（`database/database.bin` 加备份）；流式写回与半截消息因此会被周期保存。`isStreaming` 是内存字段，切换会话或重启后消失，但消息文本已持久化。
- **消息级记录**：`generationInfo` 与 `promptInfo`（预设名、toggle、可选 promptText）随消息持久化，是任务与预设的关联依据。
- **运行期日志**：fetch 日志 `addFetchLog` 带 `chatId` 可在 DevTool 查看（`alertRequestLogs`）；`chatProcessStage` 与 `doingChat` 供 UI 展示；源码中散落的 `console.log`（含完整 prompt 与记忆数据）也可作调试入口。
- **已确认边界**：
  - 请求上下文以 `requestChatData` 实际收到的数组为准，可用 preview 模式核对。
  - `escapeOutput` 角色强制关闭流式并对输出做转义（request.ts:212-214）；`useStreaming` 设置未定义时等效关闭流式（`db.useStreaming && arg.useStreaming` 为 falsy）。
  - 本次静态检查发现三个可疑点：导出但从未使用的 `abortChat` store、`/multisend` 的锁行为、IGP 子请求把返回对象直接 `+=` 到消息文本（静态看会拼出 `[object Object]`，仅在配置 `igpPrompt` 时触达）——均未运行验证。

## 11. 未验证事项

- 各 Provider 的实际网络行为、SSE 断流与重连、Claude Batch 24 小时轮询均未实测。
- 桌面端"停止"后网络请求的继续时长与资源影响、关闭窗口后 Rust 请求的存活行为未实测。
- `/multisend` 与 IGP 两个静态可疑点未运行确认其可观察效果。
- 记忆引擎的摘要质量、限速器排队耗时、HypaV3 相似度检索在长会话下的行为未实测。
- `useStreaming` 未定义时新数据库是否默认开启流式，未运行确认。
- 多选生成（`genTime > 1`）流式路径只消费第一个 choice 键的显示行为未实测。
- 群聊 talkness 排序与随机兜底在真实群聊中的分布未实测。
- autoContinue、情感识别与图片生成的触发阈值未逐行核对完毕。

## 12. 关键源码索引

- `src/ts/process/index.svelte.ts`：`sendChat`（99-2208）；`makeMs`（849-864）；逐条消息处理（900-1053）；记忆 stage2（1068-1140）；模板拼装（1271-1468）；token 重检（1500-1523）；`generationInfo`（1530-1545）；流式消费（1591-1753）；非流式回写（1795-1883）；autoContinue（1885-1904）；IGP（1906-1916）；情感/图片副链（1991-2190）
- `src/ts/process/request/request.ts`：`requestChatData`（205-346）；`requestChatDataMain`（435-534）；`reformater`（348-432）；Provider 分支（484-528）
- `src/ts/process/request/openAI/requests.ts`：`requestOpenAI`（35-665）；`requestHTTPOpenAI`（667-898）；`getTranStream`（972-1136）；`wrapToolStream`（1138-1318）
- `src/ts/process/request/anthropic.ts`：`requestClaude`（71）；Claude Batch（615-885）；`requestClaudeHTTP`（899-1210）
- `src/ts/process/request/google.ts`：`getTranStream`（978）；`wrapToolStream`（1069-1309）
- `src/ts/process/memory/`：`supaMemory.ts:12`；`hypav2.ts:335`；`hypav3.ts:118`（选择与注入 501-935）；`hanuraiMemory.ts:9`
- `src/ts/process/lorebook.svelte.ts`：`loadLoreBookV3Prompt`（75-）
- `src/ts/process/triggers.ts`：`runTrigger`（1058）；`src/ts/process/scriptings.ts`：`runLuaEditTrigger`（1409）
- `src/ts/process/scripts.ts`：`processScriptFull`（99）；`src/ts/process/command.ts`：`processMultiCommand`（11）、`/multisend`（163-181）
- `src/ts/globalApi.svelte.ts`：`saveDb`（292-486）；`globalFetch`（681）；`fetchNative`（1713）
- `src/lib/ChatScreens/DefaultChatScreen.svelte`：`sendMain`（144-216）；`reroll`/`unReroll`（218-301）；`sendChatMain`/`abortChat`（303-335）
- `src-tauri/src/main.rs`：`streamed_fetch`（433-564）
- `src/ts/tokenizer.ts`：`ChatTokenizer`（412-487）
