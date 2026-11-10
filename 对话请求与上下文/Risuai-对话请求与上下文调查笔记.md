# Risuai 对话请求与上下文调查笔记

> 调查对象：`https://github.com/kwaroran/Risuai`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`39f1ac1472d0ef6907ee933c4cf25182ee2aec9f`（分支：`main`）
>
> 调查方式：直接阅读源码（`src/ts/process/index.svelte.ts` 的 `sendChat` 全链、`request/` 各 Provider 的流式实现与工具循环、`memory/` 四个记忆引擎、`globalApi.svelte.ts` 网络层与持久化循环、`src-tauri` 的请求命令），静态追踪调用链与状态分支；未运行应用
>
> 调查范围：一次生成任务的提交入口、任务对象与状态机、历史选择与上下文拼装顺序、token 预算与记忆压缩、Provider 交接与协议适配、流式事件链与节流、完成/异常/半截流收口、停止/重试/续写/重新生成、群聊串行与并发、外部能力注入点、退出恢复与可观测性；消息与会话的 schema、Composer 与按钮工作流、流式文本的 DOM 渲染分别归会话与消息管理、Chat UI、消息渲染器类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- 一次生成由 `sendChat(chatProcessIndex, arg)` 统一驱动，入口在 `src/ts/process/index.svelte.ts:99`。代码里没有独立的任务对象：运行状态由全局生成锁 `doingChat` 与调用方参数共同表达（含阶段进度与 UI 持有的中止信号），任务的权威记录是写回消息的 `generationInfo`，其中含生成 ID、输入/输出 token 估算与四个阶段耗时。
- 上下文拼装分两遍：先用"提示词模板"卡片（或旧式 `formatingOrder` 分组）逐项预检 token 并装入分组桶，再按同一顺序把各桶拼成最终消息数组；无模板时走固定分组顺序。模板中的 persona、描述、作者注和记忆卡可将本槽位发为 user、assistant 或 system，未设置仍为 system；lorebook 条目也可提供默认角色，正文内的 `@@role` 优先。最终请求以 `requestChatData` 收到的数组为准，可用 DevTool/快捷键的 preview 模式核对（`index.svelte.ts:654-708,1273-1437`）。
- 预算以全局 `maxContext` 为上限：无记忆引擎时从消息数组头部整条删除；启用记忆后由所选引擎（SupaMemory / HypaMemoryV2 / HypaMemoryV3 / HanuraiMemory）各自截断或摘要，压缩不可逆；拼装后还有一次只清空可移除消息的 token 重检。
- 请求先在 `requestChatData` 做回退与重试包装，再由 `requestChatDataMain` 按协议格式分发，分发前先过一遍 `reformater` 的角色兼容改写（`src/ts/process/request/request.ts:484-528`）。OpenAI、Claude、Gemini 各自解析 SSE，把**累计全文**放进键为 0 的流式块，消费端每次整段替换消息文本。
- 流式占位消息在请求前就已写入会话（`chatId = generationId`），持久化由全局保存循环（500ms 防抖 + 全库编码写盘）持续进行，因此半截消息会随保存落盘，与"流结束才落定"的实现不同。
- 停止只发生在本地消费层：UI 的 `AbortController` 会中止 fetch 与流 reader；Tauri 桌面端另有 `cancel_streamed_fetch`（按 fetch id 命中 `STREAMED_FETCH_ABORTS` 中的 abort 句柄）与 `cancel_all_streamed_fetch`（页面重载时批量取消），但流长度由空闲超时控制——超过 `STREAMED_FETCH_IDLE_TIMEOUT_SECS` 未收到新数据即以失败结束（`src-tauri/src/main.rs`）。
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

- **发送入口**：聊天界面的发送函数 `sendMain()`（`DefaultChatScreen.svelte:144-216`）在 `$doingChat` 为真时直接返回；输入以斜杠开头时先交给 `processMultiCommand` 解析（`command.ts:11`），命令返回非 false 即短路本次发送。
- **消息写入与调用**：用户消息压入当前聊天，角色房先过一遍 `editinput` 正则脚本；随后 `sendChatMain` 新建中止控制器，以 `sendChat(-1, {signal, continue})` 启动生成（305-329）。
- 命令入口：`/multisend` 等命令可以在命令链内直接 `await sendChat(-1)` 触发生成（`command.ts:163-181`）。
- 状态机：模块级 `doingChat` store 是唯一锁，`sendChat` 开头遇到索引为 -1 的重复调用即返回 false（212-219）。阶段进度由 `chatProcessStage` 的 0 到 4 表达，依次对应准备、上下文构建、记忆、请求、收尾，UI 按对应的样式类渲染。导出的 `abortChat` store 全程没有被赋值，实际停止由调用方自己持有的 `AbortController` 完成。
- 任务对象：生成开始时用 `v4()` 取出 `generationId`，同一个值也用作消息的 `chatId`；`generationInfo` 记录模型串、输入/输出 token 估算、上下文上限与四个阶段耗时，任务完成后写回最后一条消息（1530-1545、2202-2205）。代码里没有独立的取消令牌、任务注册表或队列对象。
- 群聊：`chatProcessIndex === -1` 且房型为 group 时，按排序后的成员列表循环 `await sendChat(i)`，任一成员返回 false 则整批停止（295-336）；成员调用因索引非负可绕过锁。

## 2. 历史选择与上下文拼装顺序

按 `sendChat` 的实际执行顺序：

1. **消息选择**：`makeMs` 从最后一条往前收集可用消息，字段 disabled 为 true 的条目直接跳过；遇到 allBefore 标记时，把它之前的消息全部丢弃（849-864）。
2. **开场白**：非群聊且未重置时取 `firstMessage` 或 `alternateGreetings[fmIndex]`，经 `editprocess` 处理作为 assistant 消息加入（868-884）。
3. **系统桶**：主提示词由角色的 `systemPrompt` 替换 `{{original}}` 占位后并入全局主提示词，再按开关决定是否带上 jailbreak；全局注释与作者注释（取聊天 note，缺省用默认值）同样进这一桶。chain-of-thought 的思考指令单独放进 postEverything 桶（410-464）。
4. **角色字段**：description（desc + 嵌入补充信息 `additionalInformations` + personality + scenario，466-496）；群聊再追加"只扮演当前角色"指令。
5. **lorebook 分流**：`loadLoreBookV3Prompt` 扫出的激活条目按各自位置分派——没有位置要求的进 lorebook 桶，before_desc、after_desc、personality 与 scenario 四处的条目围在角色描述消息两侧，深度为 0 的进 postEverything 桶，角色为 assistant 的条目延后处理（498-611）。
6. **位置引用**：条目里的 `{{position::}}` 引用在注入时逐层解析，最多嵌套 5 层（500-527）。
7. **persona 与视图指令**：`personaPrompt` 开关、inlayViewScreen 的 emotion/imggen 指令进 postEverything（560-580）。
8. **示例与开场占位**：`exampleMessage` 生成示例对，随后加入 `[Start a new chat]` 占位（novelai 与 trimStartNewChat 除外）（831-845）。
9. **逐条消息处理**：历史消息逐条过一遍 `editprocess`，依次跑正则脚本、Lua 的 editInput 钩子与宏替换，并从中提取 inlay 附件、思维块和图片占位；群聊消息按 `groupTemplate` 包装，角色字段依 `groupOtherBotRole` 的设置改写（900-1053）。
10. **depth lorebook 与记忆**：`depth > 0` / `reverse_depth` 条目按深度插入历史；随后进入记忆引擎阶段（1056-1140）。
11. **收尾桶**：无模板时把最后一条消息拆进末尾桶；模板含 memory 卡时，记忆消息替换成空 system 由模板位置注入，否则包上 `<Previous Conversation>` 标签；`start` 触发脚本的附加提示按 start、historyend、promptend 三个位置插入；续写模式再追加一条续写指令（1164-1233）。
12. **拼装**：有模板时按卡片类型顺序逐卡 `pushPrompts` 生成最终数组，相邻的同角色 system 消息会合并；无模板时直接按 `formatingOrder` 的分组顺序拼（1235-1258）。卡片顺序为：

    ```
    persona → description → authornote → lorebook → postEverything → plain/jailbreak/cot → chatML → chat → memory → cache
    ```

    `chat` 卡的 rangeStart/rangeEnd 决定历史范围、`sendChatAsSystem` 时整段转 system（1383-1426）；自动缓存点在 chat 卡后标记最近 3 条 user 消息（1413-1426）。随后插入角色 depth_prompt、跑 Lua `editRequest` 钩子（1484-1497），才进入请求层。

## 3. 预算、截断、摘要与压缩

- **预算来源**：预算上限只有全局 `maxContext` 一处；已用 token 数从 `maxResponse + 50` 起算，此后每加入一条消息就用 `ChatTokenizer.tokenizeChat` 累加一次，普通消息另按 3 或 5 个 token 附加，消息名与多模态内容还要额外折算（`src/ts/tokenizer.ts:412-487`）。
- **输出预算**：在请求前估算为 `maxResponse`，超上限时压到 `maxContext - inputTokens`（1526-1529）。
- **无记忆截断**：预检与逐条构建期间只累计不裁剪；stage 2 之后 `while (currentTokens > maxContextTokens)` 从数组头部整条删除（1141-1154），全删仍超限则报错中止。
- **记忆引擎选择**：房间的 `nowChatroom.supaMemory` 打开、且子模型类型不为 none 或 Hanurai、HypaV2、HypaV3 三个开关中至少一个开启时，才进入 stage 2；多个引擎同时可用时按 Hanurai、HypaV2、HypaV3、SupaMemory 的优先级选取（1068-1140）。
  - SupaMemory（`memory/supaMemory.ts:12`）：先把历史裁到上次记忆点，超预算后按上下文的三分之一（上限 `maxSupaChunkSize`）分块调用总结模型，单块过大时按 0.7 缩放，旧记忆超过 4 段则先压缩。摘要作为 system 消息插到消息数组头部，同时写回 `room.supaMemoryData`——纯文本模式存记忆点加换行加摘要，hypa 模式存 JSON；总结子请求以 memory 模式发起，非流式（25-135、286-376、378-427）。
  - HypaMemoryV2（`memory/hypav2.ts:335`）：从上次摘要覆盖点继续，逐批摘要并保留最后 4 条消息，摘要分块存向量，按比例预留记忆 token。
  - HypaMemoryV3 预算（`memory/hypav3.ts:118-466`）：先按记忆占比参数 `memoryTokensRatio` 预留记忆预算。超预算时从摘要起点分批取 `maxChatsPerSummary` 条消息，跳过示例、空消息和可配置的 user 消息，一直取到条数下限 `queryChatCount` 或目标线 `maxContext * (1 - extraSummarizationRatio)`。摘要经限速器（子模型按并发与每分钟上限，本地模型串行）完成后写入 `room.hypaV3Data`。
  - HypaMemoryV3 注入：按 important → recent → similar（嵌入检索）→ random 四路选择填充预留预算，最终以 `<Past Events Summary>` XML 块作为头部 system 消息（877-935）。
  - HanuraiMemory（`memory/hanuraiMemory.ts:9`）：对历史做嵌入检索取高相关片段，同时从头部弹出直到预算内，检索结果作为 system 消息注入。
- **最终重检**：拼装后 `inputTokens > maxContext` 时从头扫描，只清空 `removable` 消息的内容再过滤（1500-1523）；记忆注入的消息不可移除。压缩不可逆，不会回填。
- **记忆数据落点**：无记忆路径下，`currentChat.lastMemory` 记录保留下来的最早一条消息的 chatId（1153）；三个引擎各自的数据分别存在会话对象的 supaMemoryData、hypaV2Data、hypaV3Data 字段中（`src/ts/storage/database.svelte.ts:1823-1834`）。

## 4. Provider、模型与协议交接

- **请求包装**：`requestChatData(arg, model, abortSignal)` 先复制入参并做一次 `risuUnescape` 反转义，再进入"回退模型 × 重试"的双层循环：回退列表取当前模型的 `fallbackModels` 条目，末尾补一个空串代表主模型尝试（`request/request.ts:205-228`）。
- **尝试前钩子**：每次尝试先跑插件 `replacerbeforeRequest` 与 `request` 触发脚本（可改写 formated，247-265），再调 `requestChatDataMain`（268-272）。
- **失败分类**：同一模型按 `requestRetrys`（默认 2）重试。服务端超载即 `failByServerError` 命中时，先 sleep 1 秒，`antiServerOverloads` 开启则重试计数减半；结果命中 `banCharacterset` 脚本集时整段重试；返回空白且开启 `fallbackWhenBlankResponse` 时切到下一个回退模型（291-337）。
- **模型解析**：`requestChatDataMain` 按 mode 选模型——mode 为 model 时用主模型，记忆、情感、翻译、子模型等其余 mode 用子模型；开启 `seperateModelsForAxModels` 后，每个 mode 可以单独指定模型。自定义代理（`reverse_proxy` 与 `xcustom:::`）的 URL 和 key 也在这里注入（435-534）。
- **角色兼容**：`reformater`（348-432）按模型能力 flags 处理——无完整 system 支持时折叠或改写 system、要求角色交替时合并连续同角色消息、要求以 user 开头时补占位。
- **协议分发**：按 `LLMFormat` 枚举做 switch，不同格式落到不同的 Provider 实现。OpenAI-compatible 与 Mistral 交给 `requestOpenAI`，Responses API 走 `requestOpenAIResponseAPI`，Anthropic 与 Bedrock 走 `requestClaude`，Gemini 走 `requestGoogleCloudVertex`；另有 NovelAI、Ooba、Ollama、Kobold、Horde、Cohere、WebLLM、插件与 Echo 等分支。每个实现自行拼协议 body、解析端点，并决定走流式还是整包返回（484-528）。
- **网络路由**：所有 Provider 都经同一网络层发出请求。浏览器环境默认走服务端代理，用 `risu-header` 和 `risu-url` 两个头带上目标地址；Tauri 桌面端改为调用 Rust 侧的 `streamed_fetch` 命令，由 reqwest 做流式转发；显式 timeout_secs 使用总超时，未设置时按等待响应及相邻数据块的空闲时间限制，默认阈值为 600 秒（`src-tauri/src/main.rs:181,339-368`）。节点自托管另有独立代理通道，请求出口是 `src/ts/globalApi.svelte.ts` 里的 globalFetch 与 fetchNative。
- **超时与日志**：`buildTimeoutSignal` 给请求套可选超时；请求携带 `chatId` 供 fetch 日志关联。
- 与 SillyTavern 相比，Risuai 各 Provider 是独立实现而非统一 Adapter 接口，消息构建全部在 TS 侧完成，Rust 端只做字节转发、不解析 SSE。

## 5. 流式事件、缓冲、节流与顺序

- **OpenAI 流**：请求经 `fetchNative` 发出时带上 openai_streaming 拦截器，拿到原始 SSE 响应体；`getTranStream` 逐行读取 `data: ` 前缀的内容并累积成文本（`request/openAI/requests.ts:972-1136`）。
- **块契约**：每个输出块是**累计全文**的 `{"0": text}`（多选生成按 choice index 分键，并附带累积的 `__tool_calls`）；`[DONE]` 时一次性 flush。
- **流内后处理**：reasoning 字段包成 `<Thoughts>`，开启 `extractJson` 时在结束时提取 JSON 字段。
- **Anthropic 流**：同样解析 SSE 事件，把 text、thinking 与 redacted_thinking 三类增量拼成 `<Thoughts>` 包裹的累计文本；遇到 overload 错误事件且开启了 `antiServerOverloads` 时自动重连继续取流（`request/anthropic.ts:899-1051`）。
- **Claude Batch**：开启批量模式时提交 `batches` 端点后轮询状态，把最终结果包装成单个流式块；中止会先调用批量取消端点（615-885）。
- **Gemini 流**：`wrapToolStream` 的结构与 OpenAI 一侧同构，另把思维与签名两个字段（`__thoughts`、`__sign_text`）拼入文本（`request/google.ts:1069-1309`）。
- **消费端占位与续写**：占位消息在读取前已 push（空 data），续写时改为取上一条文本做前缀（1591-1610）。
- **消费循环**：循环调用 reader 读取下一块，取首个键对应的累计全文，过一遍 `processScriptFull` 的 editoutput 处理（正则、Lua 的 editOutput 钩子与宏），再把整段写回消息数据并递增 `reloadKeys` 触发重新渲染；开启 `removeIncompleteResponse` 时按标点截掉半句（1687-1753）。
- **节流**：`streamingDisplayOptimizationMode` 分 off/balanced/strong 三档——balanced 与 strong 用 125ms 定时器加 `requestAnimationFrame` 把多个块合并为一次写回，strong 还把后处理推迟到流结束（1612-1681）；消费本身是单 reader 顺序执行，无并发。
- **事件时机**：流结束后才依次执行 `output` 触发脚本、inlay 屏幕、插件 `chatOutput` 监听器与 TTS（1761-1793），不随 token 触发。

## 6. 完成、异常、半截流与最终回写

- **流式完成**：读取结束后把 `isStreaming` 置为 false，并把最后一个流式块里的**全部候选值**交给 `addRerolls`，作为多选与多生成候选切换的来源（`prereroll.ts:26`，调用处 1748-1759）。
- **收尾链**：`runCurrentChatFunction` 把最新消息重新做一次宏解析 → `output` 触发脚本（可 `sendAIprompt` 触发整轮重发）→ inlay 屏幕（含异步生成）→ 插件 chatOutput 监听 → 可选 TTS（1761-1793）。
- **非流式完成**：`success`/`multiline` 结果逐条写入消息（续写时合并进上一条），同样过 editoutput 与 inlay（1795-1883）；multiline 的多条都进 rerolls 候选。
- **异常**：请求结果为 fail 类型时走 `throwError`——默认弹出错误框；开启 `inlayErrorResponse` 后，把 risuerror 代码块追加到上一条角色消息，没有可追加的消息就新建一条错误消息（159-210）。流式读取抛出的非中止错误沿调用链冒泡，由 UI 的 try/catch 弹出。
- **半截流**：中止（signal 或 reader 异常）后返回 false，半截文本连同 `generationInfo` 保留在消息中；流式期间的消息文本已经过保存循环落盘。这里没有"流结束后一次性落定"的阶段，也没有 `beforeunload` 时的流中止逻辑（见第 10 节）。
- **自动续写**：完成后 token 数低于 `autoContinueMinTokens`，或非标点结尾且开启 `autoContinueChat` 时，以 `continue: true` 递归 `sendChat`（1885-1904）。
- **副链请求**：IGP 提示词非空时，主请求结束后再追加一次情感模式的子请求，并把结果拼到末条消息（1906-1916）；情感视图（嵌入相似度或 token bias 两条实现）与图片生成（`imggen` 走 stableDiff）都在主链收尾后执行（1991-2190）。

## 7. 停止、重试、续写与重新生成

| 机制 | 触发者 | 执行层语义 |
|---|---|---|
| 停止 | 停止按钮 `onclick={abortChat}`（DefaultChatScreen.svelte:331, 662） | 调用方 `AbortController.abort()` → `sendChat` 内的 `reader.cancel()`（1682-1686）与 fetch signal；返回 false，半截消息保留；桌面 fetch 层还监听 signal，按请求 ID 调用 Rust 取消命令（见第 10 节） |
| 自动重试 | `requestChatData` 双层循环 | `requestRetrys`(2) 次同模型重试、`banCharacterset` 结果重试、`failByServerError` 慢重试、`fallbackModels` 模型回退（request.ts:222-339） |
| 续写 | 发送按钮的续写分支 `sendMain(true)`；autoContinue | 最后一条角色消息留在上下文，追加 `[Continue the last response]`；流式以原文本为前缀，非流式 append |
| 重新生成 | 消息菜单 reroll（DefaultChatScreen.svelte:218-271） | 弹出末尾消息到最近 user 边界（同角色最多回退 2 条）后重新 `sendChatMain()`；成功后新结果进 `rerolls` 数组；`unReroll` 用 `prereroll.ts` 的 `Prereroll`/`PreUnreroll` 按 generationId 恢复旧文本（273-301），不重新请求 |
| 多候选 | 多选生成 `genTime > 1`（仅 gpt 系、非续写） | 非流式返回 `multiline` 多条消息；流式时最后一块的多 choice 值进 rerolls 候选（request.ts:464） |

手动"重试"没有独立命令——错误后由用户重新发送或走上述机制。触发脚本的 `stopSending` 效果（`start` 钩子返回，index.svelte.ts:894-897）与 UI 停止是不同层级。

## 8. 队列、多会话并发与后台生成

- **串行粒度是全局的**：生成锁加 UI 侧的同一状态检查，使生成期间的新发送直接被拒，既不排队也不替换当前任务；同一聊天内同样没有 swipe 或队列概念。重新生成、续写与普通发送共用这把锁。
- **群聊串行**：成员按 talkness 权重与最后消息单词匹配排序（`group.ts:52` 的 `groupOrder`，排除最后发言者，随机兜底），`sendChat` 内循环逐个 `await` 生成；任一成员失败即终止整批。
- **后台生成**：项目里没有独立的后台任务系统，相邻位置有三处自建循环。输入栏的自动模式 `runAutoMode` 在 UI 层反复调用发送入口；建议功能在生成锁变成 false 时用子模型发一次非流式建议请求，并在下一次生成开始时取消；DevTool 的 autopilot 逐条发消息，间隙里手动复位锁。三处实现分别在 `DefaultChatScreen.svelte:337-348`、`Suggestion.svelte:126-133` 与 `DevTool.svelte:217-237`。
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

- **退出**：Web 端的 `beforeunload` 处理只负责阻止离开页面，不中止正在进行的生成；页面隐藏或关闭时没有对应的取消逻辑（`src/preload.ts:16`）。桌面 fetch 层监听调用方 signal，触发时以请求 ID 调用 cancel_streamed_fetch；Rust 侧通过 abort handle 取消单个请求，也提供全部请求取消入口（`src/ts/globalApi.svelte.ts:1841-1867`、`src-tauri/src/main.rs:253-266`）。窗口最终销毁时的网络与进程释放行为尚未运行验证。
- **持久化**：`saveDb` 监听 `DBState` 变化，任何会话消息改动都经 500ms 防抖触发整库编码（RisuSaveEncoder）写盘，落点是 `database/database.bin` 与其备份，流式写回和半截消息因此会被周期保存。`isStreaming` 是内存字段，切换会话或重启后消失，消息文本本身已经持久化（`src/ts/globalApi.svelte.ts:292-486`）。
- **消息级记录**：`generationInfo` 与 `promptInfo`（预设名、toggle、可选 promptText）随消息持久化，是任务与预设的关联依据。
- **运行期日志**：fetch 日志由 `addFetchLog` 记录，带上 `chatId` 后可在 DevTool 里通过 alertRequestLogs 查看；`chatProcessStage` 与 `doingChat` 供 UI 展示阶段与忙碌状态；源码中散落的 console.log（含完整 prompt 与记忆数据）也可作调试入口。
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
