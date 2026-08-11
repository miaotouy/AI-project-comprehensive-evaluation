# VCPChat Chat 调查笔记

> 调查对象：`E:\works\git\VCPChat`
>
> 调查更新日期：2026-08-05
>
> 代码快照：`3f14e938e700a5487ca13c4a6d8a6caad8e70ac9`（分支：`main`）
>
> 调查方式：逐文件精读源码 + 定向 grep 验证调用链
>
> 调查范围：聊天会话、消息状态、存储、流式更新与交互机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

> 迁移状态（2026-08-11）：本文件是迁移期保留的旧版长文，内容已按新类目边界迁移：
>
> - 会话与消息管理：[`../会话与消息管理/VCPChat-会话与消息管理调查笔记.md`](../会话与消息管理/VCPChat-会话与消息管理调查笔记.md)（Topic 数据模型、持久化格式、创建/切换、索引检索、未读计数、并发写入）
> - 对话请求与上下文：[`../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md`](../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md)（群聊调度、中断与超时、最终化落盘、话题自动总结请求）
> - Chat UI：[`../Chat UI/VCPChat-ChatUI调查笔记.md`](<../Chat UI/VCPChat-ChatUI调查笔记.md>)（工作台、Topic 导航、Composer、发送/停止反馈、消息操作、键盘与无障碍）
> - 消息渲染：[`../消息渲染器/VCPChat-消息渲染器调查笔记.md`](../消息渲染器/VCPChat-消息渲染器调查笔记.md)（已有独立笔记，内容渲染类一律链接过去，不复制）
>
> 本文件第 13 节中的通用界面盘点（弹窗库、Toast 系统、主题、动画、灯箱、全局快捷键清单）暂保留于此，待可选界面专题承接。

说明：本笔记所有判断均标注文件路径与行号证据。

## 定位

VCPChat 的聊天以 **Agent 或 AgentGroup（群组）** 为一级会话主体，二级是 **Topic（话题）**。每个 Topic 对应磁盘上独立的 `history.json`，Agent/群组配置里的 `topics` 数组只存元数据（id/name/createdAt/locked/unread），实际消息内容全部落在 `UserData/<agentId 或 groupId>/topics/<topicId>/history.json`。前端渲染、流式增量渲染、话题列表、心流锁（Flowlock）、群聊调度分别由 `chatManager.js`、`modules/renderer/streamManager.js`、`topicListManager.js`、`Flowlockmodules/flowlock.js`、`Groupmodules/groupchat.js` 承担，IPC 层落在 `modules/ipc/chatHandlers.js`（单聊）和 `modules/ipc/groupChatHandlers.js`（群聊，转发到 `Groupmodules/groupchat.js`）。

单聊与群聊在“中断请求”这一点上的实现**不对称**（见下文交互面一节），这是本次调查发现的关键问题。

## 会话与历史

### Agent/群组选择 → Topic 加载判断顺序

`chatManager.js` 的 `selectItem(itemId, itemType, ...)`（`modules/chatManager.js:352-481`）：

1. 先停掉上一个 item 的文件监听器（`electronAPI.watcherStop()`，`:356-358`）。
2. 拉取该 item 的话题列表：agent 走 `electronAPI.getAgentTopics`，群组走 `electronAPI.getGroupTopics`（`:412-416`）。
3. 若话题列表非空，按以下**优先级**决定要打开哪个 topic（`:418-430`）：
   - 默认取 `topics[0].id`（数组第一个，因为新建话题会 `unshift` 到最前面，所以实际是"最近创建的话题"）；
   - 若是 agent 类型，检查 Flowlock 锁定：`window.flowlockManager?.getLockedTopicId?.(itemId)`（`:420-422`），若锁定的 topic 仍存在于列表中则**优先**使用它（`:425-426`）；
   - 否则检查 `localStorage.getItem(\`lastActiveTopic_${itemId}_${itemType}\`)`（`:423`），若存在且在列表中则使用它（`:427-428`）。
   - 即优先级为：**Flowlock 锁定 topic > localStorage 记忆 topic > 最新创建的 topic（数组首位）**。
4. 若话题列表为空：
   - agent：先 `getAgentConfig(itemId)` 确认没有 topics，再调用 `createNewTopicForAgent(itemId, "主要对话")` 建立默认话题（`:438-454`）；
   - group：直接调用 `createNewTopicForGroup(itemId, "主要群聊")`（`:458-467`）。

注意：Agent 侧还存在**另一条**创建默认话题的路径——`modules/ipc/agentHandlers.js` 的 `create-agent` handler 在新建 Agent 时会直接写入 `topics: [{ id: "default", name: "主要对话", createdAt: ... }]`（`modules/ipc/agentHandlers.js:430`），话题 id 固定为字符串 `"default"`；而 `chatManager.js` 里 fallback 创建时调的是 `createNewTopicForAgent`，其 id 格式是 `topic_${Date.now()}`（`modules/ipc/chatHandlers.js:511`）。两条路径产生的默认话题 id 格式不一致（`"default"` vs `"topic_<timestamp>"`），是历史遗留的不一致点，非致命但值得注意。

`selectTopic(topicId)`（`modules/chatManager.js:483-537`）在用户主动点击话题列表项时被调用，同样会先检查 Flowlock：如果当前 agent 被锁定且要切换到的 topic 不是锁定的那个，直接 toast 提示并 `return`，阻止切换（`:485-495`）。切换成功后会写 `localStorage.setItem(lastActiveTopic_...)`（`:525`）并调用 `_saveLastOpenState()` 把 `lastOpenItemId/lastOpenItemType/lastOpenTopicId` 存进 `settings.json`（`:275-292`，`526`）——这是"最后打开状态持久化"的具体落点。

### Topic 持久化文件格式

路径规则（agent）：`UserData/<agentId>/topics/<topicId>/history.json`（`modules/ipc/chatHandlers.js:439`，`:459-462`）；群组同构：`UserData/<groupId>/topics/<topicId>/history.json`（`Groupmodules/groupchat.js:159`, `:500`, `:1770`, `:1825`）。文件内容是一个 JSON 数组，每条消息是一个对象，字段随场景略有不同，综合各写入点可得到字段全集：

- 通用字段：`role`（'user'|'assistant'|'system'）、`content`（字符串或 `{text}`，assistant 流式结束后是纯字符串）、`timestamp`、`id`。
- user 消息还有：`name`、`attachments`（数组，每项含 `type/src/name/size/_fileManagerData` 等，见 `modules/chatManager.js:992-1002`）。
- assistant 消息还有：`name`、`avatarUrl`、`avatarColor`、`isThinking`（流式过程中临时为 true，落盘前被 `streamManager.finalizeStreamedMessage` 置为 `false`，`modules/renderer/streamManager.js:2211`）、`finishReason`（`:2210`）。
- 群聊 assistant 消息额外带：`agentId`、`model`、`modelSource`（`'group_unified'` 或 `'agent'`，见 `Groupmodules/groupchat.js:950`）、`isGroupMessage: true`、`groupId`、`topicId`、`interrupted`（用户中断时为 true，`:1033`）。
- Agent 配置里的 `topics[]` 元素字段：`id, name, createdAt, locked（默认 true）, unread（默认 false）, creatorSource`（`modules/ipc/chatHandlers.js:492-499` 的兼容归一化逻辑）。

`history.json` 本身没有 schema 版本号或额外的 wrapper，就是裸数组，`fs.writeJson(file, history, {spaces:2})` 直接整份覆盖写（例如 `modules/ipc/chatHandlers.js:462`、`Groupmodules/groupchat.js:539`），**没有增量写入或原子写保护**（没见到先写临时文件再 rename 的模式）——如果写入过程中进程崩溃，理论上可能截断成非法 JSON，这是潜在风险点（未在代码里发现任何缓解措施，标注为"未核实是否曾经出问题"，但从实现上看确实缺乏保护）。

## 话题列表（topicListManager.js）

### 搜索

`loadTopicList()`（`modules/topicListManager.js:379-484`）读取 `#topicSearchInput` 的值作为 `searchTerm`（`:413-414`）。搜索是**前端过滤 + 后端内容检索的并集**：

- 前端过滤：对 `topic.name`（经 `normalizeTopicTitle` 归一化）和格式化后的创建时间字符串做 `includes` 匹配（`:446-457`）；
- 后端内容检索：调 `electronAPI.searchTopicsByContent(itemId, itemType, searchTerm)`（`:461`），实现在 `modules/ipc/chatHandlers.js:364-407`，会遍历该 item 所有 topic 的 `history.json`，对每条消息 `message.content` 做 `toLowerCase().includes()`（`:391`）。**注意**：这里只处理 `typeof message.content === 'string'` 的情况（`:391`），如果消息 content 是多模态数组（`[{type:'text',text:...}]`），这条内容检索会直接跳过、匹配不到——这是一个实际的搜索盲点。
- 两路结果取并集（`:471-474`）。

### 拖放排序

用 SortableJS，初始化在 `initializeTopicSortable(itemId, itemType)`（`modules/topicListManager.js:510-568`）。`onStart` 时如果全局"划词监听"（selection listener）处于开启状态会临时关闭，`onEnd` 时恢复（`:526-542`，避免拖拽过程与全局划词快捷键冲突）。`onEnd` 拿到新顺序的 `topicId` 数组后调用 `saveTopicOrder`（agent）或 `saveGroupTopicOrder`（group）（`:544-552`），对应 IPC 在 `modules/ipc/chatHandlers.js:301-332`（agent，用 `agentConfigManager.updateAgentConfig` 重排 `topics` 数组）和同文件 `:334-362`（group，直接读写 `config.json`）。排序失败会 toast 报错并 `loadTopicList()` 回滚展示（`:556-565`）。搜索状态下不启用拖拽排序（`renderTopicListProgressively` 里 `!searchTerm` 才 `initializeTopicSortable`，`:315`）。

### 未读标记：手动 vs 自动

两套机制并存，且逻辑在前端和后端各自重复实现了一份（`topicListManager.js:53-70` 与 `chatHandlers.js:1280-1297` 几乎逐行相同）：

- **自动判定**（"最后一条为 AI 回复"）：`shouldActivateCount(history)` —— 过滤掉 `role==='system'` 后，若非系统消息**恰好只有 1 条**且该条 `role==='assistant'`，则判定需要计数，返回未读数 1（`topicListManager.js:53-70`）。也就是说，这套自动逻辑只覆盖"用户发了消息、AI 回了、用户还没回"的**单轮**场景；一旦历史累积到 2 轮以上，这个自动计数条件就永远不会为真了（`nonSystemMessages.length === 1` 是硬编号 1，不是"最后一条是 assistant"这种更通用的判断）。这是笔者认为设计上比较狭窄的一点：所谓"最后一条为 AI 回复"的自动未读提示，实际代码条件是"整个 topic 历史里恰好只有一条非系统消息，且它是 assistant"，多轮对话完全不会触发自动未读。
- **手动标记**：右键菜单"标记为未读/已读"调用 `electronAPI.setTopicUnread(itemId, topicId, !isUnread)`（`topicListManager.js:713-716`），写入 `topic.unread` 字段（`chatHandlers.js:1424-1469`）。
- 汇总函数 `calculateTopicUnreadCount(topic, history)`（`topicListManager.js:93-106`）：优先看自动判定结果（>0 就返回数字），否则看 `topic.unread===true` 就返回 `-1`（约定 `-1` 表示"只显示小红点、不显示数字"），否则返回 0（不显示）。UI 侧据此给 `.message-count` 加 `has-unread`（数字）或 `unread-marker-only`（小点）class（`:179-191`）。

### IntersectionObserver 延迟计数

每个话题列表项创建时先把 `message-count` 文本设为占位符 `'...'`（`topicListManager.js:233-235`），并 `ensureTopicCountObserver().observe(li)`（`:250-251`）。Observer 用 `rootMargin: '240px 0px', threshold: 0.01`（`:140-144`），条目滚入视口附近时才触发 `loadTopicMessageCount(li)`（`:149-205`），该函数据 `li.dataset` 读取 `itemId/itemType/topicId`，异步拉取该话题完整 `history.json` 算未读数和总消息数，**触发一次后立即 `unobserve`**（`:137`）且用 `dataset.countLoaded` 防止重复加载。这个设计的意义是：列表可能有大量话题，如果一次性给每个话题都发一次 IPC 读取历史文件会造成打开列表时的 IO 风暴，用 IntersectionObserver 把这个成本摊到"用户实际滚动到看见"的时刻。

配合的还有话题列表本身的**渐进渲染**：初始只渲染 `TOPIC_INITIAL_RENDER_COUNT = 40` 条，之后每次滚动触底（阈值 `TOPIC_LOAD_MORE_THRESHOLD_PX = 320`）追加 `TOPIC_PROGRESSIVE_BATCH_SIZE = 30` 条（`topicListManager.js:16-18`, `:288-377`），用 `requestAnimationFrame` 分帧渲染避免一次性插入大量 DOM 卡死主线程。

## 话题标题自动总结

**单聊（agent）路径**：`chatManager.js` 的 `attemptTopicSummarizationIfNeeded()`（`modules/chatManager.js:896-947`），触发时机是 `renderer.js` 在收到 VCP 流 `'end'` 事件、且该消息属于当前可见视图、且不是群聊消息时调用（`renderer.js:568-569`）。触发条件（`chatManager.js:901`）：`currentSelectedItem.type === 'agent'` 且 `currentChatHistory.length >= 4`（至少两轮对话）且 `currentTopicId` 存在。默认名判断（`:920-923`）：重新从磁盘拉取最新 agent 配置后，若当前 topic 的 `name === "主要对话"` 或以 `"新话题"` 开头，才认为是"默认名"，进而调用 `messageRenderer.summarizeTopicFromMessages`（最终转发到 `window.summarizeTopicFromMessages`，即 `modules/topicSummarizer.js:11`）请求 AI 总结，成功后 `electronAPI.saveAgentTopicTitle` 落盘（`:927`）。

**关键发现：单聊总结请求没有超时保护。** `modules/topicSummarizer.js` 里的 `summarizeTopicFromMessages` 直接 `fetch(settings.vcpServerUrl, {...})`（`:44-56`），**没有 `AbortController`，没有 `setTimeout` 兜底**。如果 VCP 服务器对这次总结请求没有响应或响应极慢，这个 `await fetch` 会一直挂着，且由于 `attemptTopicSummarizationIfNeeded` 是在正常发消息流程收尾时 `await` 调用的（`renderer.js:569`），虽然不会阻塞其它消息发送（因为它是独立触发的异步回调），但也没有任何机制探测/中止这个悬挂请求。

**群聊路径**：`Groupmodules/topicTitleManager.js` 的 `generateTitleFromAI`（`:76-130`），**有明确的 20 秒超时**：`const controller = new AbortController(); const timeoutId = setTimeout(() => controller.abort(), 20000);`（`:86-87`），并在 `finally` 里 `clearTimeout`。触发条件在 `triggerSummarizationIfNeeded`（`:142-195`）：`groupHistory.length >= MIN_MESSAGES_FOR_SUMMARY(=4)` 且当前话题名是 `DEFAULT_TOPIC_NAMES = ["主要群聊"]` 中的一个，或以 `"新话题"` 开头（`:8`, `:151`）。清洗逻辑 `cleanSummarizedTitle`（`:15-30`）会去掉标点、数字编号、常见前后缀，截断到 15 字符，若清洗后为空则回退为 `"AI总结话题"` 常量，且如果最终标题等于这个回退值或与原标题相同，则**不会**写回（`:184-188`），避免把占位字符串当真标题存进配置。

也就是说**同一功能（话题自动总结）在单聊和群聊两条代码路径里的健壮性不对等**——群聊有超时保护，单聊没有。这是本次调查发现的具体设计缺口。

## 交互面：发送按钮 ⇄ 中止回复，与半截流落盘

### 按钮态与中断触发

`renderer.js` 里 `updateSendButtonState()`（`:190-198`）根据 `getInterruptibleMessageForCurrentChat()`（`:150-188`）是否返回非空来切换按钮的 `dataset.mode` 为 `'interrupt'` 或 `'send'`，并替换按钮内部 SVG（方块图标代表"中止"）。判定逻辑：先在当前内存 `currentChatHistory` 里从后往前找一条 `role==='assistant'`，若其 `isThinking===true` 或其 DOM 节点带 `.streaming` class，就认为"当前有活跃回复"（`:151-162`）；如果历史里没找到，再兜底查 `window.streamManager.getActiveStreamingMessageId()` 加当前上下文校验（`:164-187`）——这层兜底是为了覆盖"消息还没写进 `currentChatHistory` 但 streamManager 已经在流式处理"的时间窗口。

点击后走 `handleSendButtonAction()`（`:249-258`）→ 若有活跃消息则 `interruptActiveResponseFromSendButton()`（`:200-247`），否则走正常发送。

### 中断请求的实际执行路径——单聊与群聊不对称

`interruptActiveResponseFromSendButton()`（`renderer.js:200-247`）区分群聊/单聊：

- 群聊：`chatAPI.interruptGroupRequest(activeMessage.id)`（`:218`）→ IPC `redo`/`interrupt-group-chat` 系列 → `Groupmodules/groupchat.js` 的 `interruptGroupRequest(messageId)`（`:1910-1954`）。这里**确实**维护了一个 `activeRequestControllers = new Map()`（`groupchat.js:28`），每次给某个 agent 发起 fetch 前用 `activeRequestControllers.set(messageIdForAgentResponse, controller)`（`:866`）注册，`interruptGroupRequest` 拿到后**真的调用 `controller.abort()`**（`:1914`）中断本地 fetch/reader，然后再补发一次远端 `/v1/interrupt` POST（`:1917-1947`）。本地 `AbortError` 分支（`:1030-1039`）会把已累积的 `accumulatedResponse` 连同 `interrupted:true` 标记写入 `groupHistory` 并发 `'end'` 事件——**中断即真正停止本地流读取，并把已生成部分落盘**，这条路径设计是自洽的。

- **单聊**：`interruptHandler.interrupt(activeMessage.id)`（`renderer.js:222-223` → `modules/interruptHandler.js:18-42`）只是转发 `electronAPI.interruptVcpRequest({messageId})`，落到 `modules/ipc/chatHandlers.js:1226-1271` 的 `interrupt-vcp-request` handler。**这个 handler 完全没有本地 AbortController**：它只是读 `settings.json` 拿 `vcpServerUrl/vcpApiKey`，拼出 `/v1/interrupt` 的 URL，`fetch(interruptUrl, {method:'POST', body:{requestId: messageId}})` 发一个远端信号（`:1246-1255`），然后就返回了。而真正在跑的流式请求，在同文件的 `send-to-vcp` handler（`:811-1222`）里，`fetch(finalVcpUrl, {...})` 时**没有创建/传入任何 `AbortController.signal`**（`:1061-1068`），拿到 `response.body.getReader()` 后交给内部的 `processStream(reader, decoder)`（`:1135-1195`）一直 `await reader.read()` 直到服务端主动结束流或连接关闭。

  换句话说，单聊场景点击"中止回复"，**本地读取循环完全不会被打断**，UI 上是否真正停止完全取决于远端 VCP 服务器收到 `/v1/interrupt` 后是否老实地停止推送、关闭响应流。如果远端没有及时响应（网络问题、服务端 bug、或者 `/v1/interrupt` 本身在代理链路的某一跳没被正确转发），前端会一直显示"中止已发送"的 toast，但实际内容仍会持续流入直到远端自己断流。

  与此形成对照的是：仓库里还存在一份 `modules/vcpClient.js`，其中的 `sendToVCP`/`interruptRequest` 实现了**完整**的本地 `AbortController` 管理（`activeRequests` Map，`vcpClient.js:283-291` 还带 300 秒超时自动 abort），本应是正确的单聊中断实现，但经过 grep 全仓库确认它**从未被 `main.js` 或任何其它文件 `require`**（`main.js` 里注册的是 `chatHandlers.initialize`，且 `main.js:1231` 附近甚至有注释说"VCP Server Communication is now handled in modules/ipc/chatHandlers.js"）——`vcpClient.js` 是彻底的死代码/被架空的重构半成品，真正跑的还是 `chatHandlers.js` 里那份没有本地 abort、也没有请求超时的实现。相应地，单聊的 VCP 请求也**没有任何客户端超时**（群聊侧在 `groupchat.js:865` 有明确 60 秒 `AbortController` 超时；单聊侧无对应机制），如果远端挂死，单聊窗口会无限等待，中止按钮也救不了。

  **这是本次调查里最值得写进结论的设计问题**：中断能力在群聊和单聊之间不对称实现，单聊缺乏客户端超时和真正的本地中断，是一个真实存在、有代码证据的可靠性缺口。

### 半截流最终化落盘

不管中断是否成功打断本地流，最终收尾都走同一个函数：`modules/renderer/streamManager.js` 的 `finalizeStreamedMessage(messageId, finishReason, context, finalPayload)`（`:2122-2320`）。要点：

- 若消息还处于 `'pending'`（尚未完成初始化）就收到 finalize 事件，会先缓存到 `pendingFinalizationEvents`，等 `startStreamingMessage` 完成初始化后重放（`:2124-2127`, `:1710-1722`）——防止 finalize 事件抢在初始化之前到达导致丢消息。
- 文本选择逻辑（`:2171-2191`）：优先用本地累积的 `accumulatedStreamText`，但如果 `finalPayload.fullResponse`（主进程侧提供的兜底文本）更长，或包含 `[!WARNING]` 标记（说明是错误恢复场景），就采用 `payloadFullResponse` 代替——这是为了兼容"流式中途出错，主进程把已收到的部分文本通过 error 事件的 `fullResponse` 字段回传"的场景（对应 `renderer.js:588-591` 给错误消息追加"流式响应中断"提示）。
- 找到历史数组里对应消息、写回 `content/finishReason/isThinking=false`（`:2208-2211`），如果是当前视图会同步刷新 DOM 和 `currentChatHistoryRef`（`:2218-2284`）。
- 存盘走 `debouncedSaveHistory`（**1 秒防抖**，`streamManager.js:348-375`），但**群聊消息永远不在这里存盘**——`saveHistoryForContext` 一进来就 `if (context.isGroupMessage) return;`（`:379-383`），注释解释是"群聊由主进程 `groupchat.js` 作为历史单一真源，避免渲染进程重复保存造成竞态"。也就是说群聊的落盘完全依赖 `groupchat.js` 里各个 `fs.writeJson(groupHistoryPath, ...)` 调用（前面提到的 `AbortError` 分支、正常结束分支等各自都会写一次），streamManager 只负责 UI。

## 群聊调度逻辑（groupchat.js）

三种发言模式通过策略对象注册在 `CHAT_MODES`（`groupchat.js:22-26`）：

- **sequential**（`Groupmodules/modes/sequentialMode.js`）：`determineSpeakers` 直接返回全部 `activeMembersConfigs`，即所有成员按配置里的成员顺序全部发言一轮（无随机性）。
- **naturerandom**（`Groupmodules/modes/natureRandomMode.js`）：按优先级依次判定——① `@角色名` 直接提及（`:68-78`）；② tag 匹配，`strict` 模式看 tag 是否出现在最近 8 条历史上下文或当前用户消息中（`:166-173`），`natural` 模式区分 tag 来源（用户/其他 agent 提及 vs 自己历史消息里提到自己的 tag，前者 100% 触发，后者按"是否是刚发言的人"给 0.2~0.75 的动态概率，`:102-161`）；③ `@所有人`（`:178-188`）；④ 未触发成员按 15% 基础概率（`strict` 模式下如果 tag 命中过历史上下文可提升到 85%，`:194-220`）；⑤ 保底：以上全部落空时随机选一个成员发言，避免群聊完全沉默（`:226-247`）；最后按"tag 是否命中用户最新发言"排序，命中的排最前（`:253-265`）。
- **invite_only**（`Groupmodules/modes/inviteOnlyMode.js`）：`determineSpeakers` 直接返回空数组，AI 完全不自动发言，只能通过前端"邀请发言"按钮触发 `handleInviteAgentToSpeak`（`groupchat.js:1130`起）。

### 发言顺序与防止消息交错

`handleGroupChatMessage`（`groupchat.js:477-1118`）内部，`agentsToRespond` 列表用**普通 `for...of` 循环 + 每次内部 `await`** 串行处理（`:579`起，注释明确写"按顺序让选中的 Agent 发言 (严格串行处理)"，`:578`）。关键在于：

- 循环体内每个 agent 的上下文构建（`contextForAgentPromises`，`:611-719`）都是基于**同一个内存变量 `groupHistory` 数组**的当前状态，而不是每次重新读盘（尽管注释里讨论过"频繁读写文件"的取舍，`:585-591`，但最终实现选择了内存数组 + 各阶段写盘）；
- 每个 agent 说完话后，无论流式还是非流式，都会 `groupHistory.push(...)` 后立即 `await fs.writeJson(groupHistoryPath, groupHistory, {spaces:2})`（例如流式结束分支 `:950-952`，`[DONE]` 分支 `:965-967`，非流式分支 `:1062-1064`），下一个 agent 在构建自己的上下文时就能看到上一个 agent 刚说的话——这就是"同一 topic 内多个 Agent 发言不交错"的实现基础：**因为是严格的串行 await 循环，不存在并发 fetch，天然不会有两个 agent 的流式 chunk 交错写入同一个 messageId**。

- 但这个"串行"只保证了**单次 `handleGroupChatMessage` 调用内部**的顺序，并没有对**多次调用之间**加锁。如果用户在上一次群聊消息还在处理中（比如某个 agent 的回复还没写完）时再次发送消息，或者同时点了"邀请发言"按钮（`handleInviteAgentToSpeak` 是完全独立的另一个函数，同样在开头 `await fs.readJson(groupHistoryPath)` 读一次全量历史 `groupchat.js` 附近逻辑与 `handleGroupChatMessage` 类似），两次调用各自持有自己的内存 `groupHistory` 快照，各自在结尾 `fs.writeJson` 整份覆盖写——**没有看到任何文件锁、互斥量或版本号校验**。理论上后写入的调用会把先写入的调用追加的内容覆盖掉（丢消息），这是一个真实存在但未被验证触发过的并发风险点（标注"未核实是否在实际使用中触发过"，因为需要构造并发场景才能验证，但代码层面确实没有防护）。

- 单个 agent 的 fetch 请求本身有 60 秒超时（`AbortController` + `setTimeout(() => controller.abort(), 60000)`，`groupchat.js:864-865`），超时或中止都会被 `AbortError` 分支捕获并把已累积内容落盘（`:1030-1039`），这点比单聊健壮。

## 取舍与设计问题小结

- Agent/群组 → Topic 的两级模型天然适合"多角色 + 长期关系"场景，但配套了 Flowlock（自动续写心流锁）、群聊多策略调度、桌面画布推送（`streamManager.js` 里大段 `DESKTOP_PUSH` 相关逻辑）等重型运行时机制，比通用聊天客户端复杂得多。
- **单聊中断是不完整的**：没有本地 `AbortController`，没有客户端超时，中止按钮只发一个远端信号，效果完全依赖远端服务器配合；同一功能在群聊侧（`groupchat.js`）却做得很扎实（本地 abort + 60 秒超时）。仓库里还留着一份实现正确但从未接入的 `modules/vcpClient.js`，说明这可能是一次未完成的重构。
- **话题自动总结的超时保护也不对称**：单聊 `topicSummarizer.js` 无超时，群聊 `topicTitleManager.js` 有明确 20 秒超时。
- **群聊历史写盘缺乏并发保护**：多次 `handleGroupChatMessage`/`handleInviteAgentToSpeak` 调用之间没有锁，理论上存在互相覆盖写丢消息的风险。
- **话题内容搜索有盲点**：`searchTopicsByContent` 只匹配字符串型 `content`，多模态数组内容匹配不到。
- **未读自动判定比描述的更窄**：只在"整个历史仅有一条 assistant 消息"时触发，多轮对话不会自动标未读，日常使用中这个自动判定几乎只在"刚开一个新话题、AI 回了第一句"这一瞬间生效。
- `history.json` 是整份覆盖写，没有原子写（临时文件+rename）保护，进程崩溃时点存在截断风险（未实际验证过是否发生过，仅代码层面推断）。

## 主要依据（文件与关键行号）

- `modules/chatManager.js`：`selectItem` `:352-481`，`selectTopic` `:483-537`，`loadChatHistory` `:562-673`，`attemptTopicSummarizationIfNeeded` `:896-947`，`handleSendMessage` `:949-1450`
- `modules/topicListManager.js`：`shouldActivateCount/calculateTopicUnreadCount` `:53-106`，`ensureTopicCountObserver/loadTopicMessageCount` `:129-205`，`loadTopicList` `:379-484`，`initializeTopicSortable` `:510-568`
- `modules/renderer/streamManager.js`：`startStreamingMessage` `:1556-1733`，`appendStreamChunk` `:2029-2120`，`finalizeStreamedMessage` `:2122-2320`，`saveHistoryForContext`（群聊不落盘）`:377-396`
- `modules/topicSummarizer.js`：`summarizeTopicFromMessages`（无超时）`:11-109`
- `Groupmodules/topicTitleManager.js`：`generateTitleFromAI`（20 秒超时）`:76-130`，`triggerSummarizationIfNeeded` `:142-195`
- `Groupmodules/groupchat.js`：`handleGroupChatMessage` `:477-1118`，`activeRequestControllers`/超时/中止 `:28`, `:864-899`, `:1030-1039`, `:1910-1954`
- `Groupmodules/modes/{sequentialMode,natureRandomMode,inviteOnlyMode}.js`：三种发言模式的 `determineSpeakers`
- `modules/ipc/chatHandlers.js`：`send-to-vcp`（无本地 abort/超时）`:811-1222`，`interrupt-vcp-request`（仅远端信号）`:1226-1271`，`search-topics-by-content` `:364-407`，未读计数后端实现 `:1280-1368`
- `modules/vcpClient.js`：完整但未被使用的 `sendToVCP`/`interruptRequest` 实现（死代码），`:1-544`
- `modules/interruptHandler.js`：`:18-42`
- `renderer.js`：按钮态与中断触发 `:150-262`，`onVCPStreamEvent` 分发 `:523-747`
- `Flowlockmodules/flowlock.js`：Session 状态机、锁定 topic 查询 `getLockedTopicId` `:554-557`

## UI 交互与呈现补充

### 1. 主界面布局不是单一聊天页

`main.html` 将窗口拆成左侧 sidebar、中央 chat、右侧 notifications sidebar。左侧用“助手 / 话题 / 设置”三个 tab，助手 tab 负责 Agent/Group 选择，话题 tab 负责 Topic 搜索与列表，设置 tab 打开全局配置；窄侧栏另有 compact navigation。`renderer.js` 在启动时把这些 DOM 节点注入各模块，并根据 `sidebarWidth`、`notificationsSidebarWidth`、`sidebarActive` 和 `sidebarAvatarOnly` 恢复布局状态。窗口侧栏可拖拽调整宽度，通知栏可独立开关，因而“会话选择”和“消息阅读”是并列的工作区而非路由跳转。

### 2. 三种聊天呈现模式是同一消息数据的 CSS/渲染投影

`main.html` 提供 `bubble`（气泡）、`panel`（统一面板）和 `immersive`（刊物/沉浸）三个选项，顶部还有快速切换器；`renderer.js` 的 `applyChatPresentationMode` 通过 body class 和 CSS 变量切换宽度、字体、用户气泡元信息等参数，并调用 `messageRenderer.refreshLayoutDependentState()`。它不会转换 `history.json`，也不会创建不同的消息组件树。该设计使用户可以在阅读过程中切换视觉风格，同时保留当前 Topic、滚动位置和流式状态。

### 3. 消息呈现：Markdown 管线 + 可折叠协议块

`modules/messageRenderer.js` 的 `renderMessage` 先对 LaTeX、代码围栏和 VCP 标记做保护，再走 Markdown/HTML 内容管线，随后处理图片、Mermaid、按钮、动画和桌面推送。工具调用、工具结果、思考链、DailyNote、Flowlock 和角色分隔符都渲染成独立的 bubble block；工具结果和思考链标记为 `collapsible`，在 `chatMessages` 上用事件委托点击标题切换 `.expanded`。右键菜单由 `messageContextMenu` 统一承接复制、编辑、重新生成、分支/删除等消息操作；中键快捷动作另有独立 delegated handler。也就是说协议文本仍在历史里，但可见层不是原始纯文本，而是多个可交互的 DOM 子块。

### 4. 输入、流式和停止交互

`main.html` 的 `textarea#messageInput`、附件预览区和 `sendMessageBtn` 组成固定底部输入卡，`renderer.js` 根据当前上下文是否存在 `isThinking/streaming` 的 assistant 消息，把发送按钮替换成方块图标的“中止回复”按钮。单击由 `handleSendButtonAction` 在发送和中断之间切换；流事件经过 `streamManager`/`messageRenderer` 追加到现有 DOM，结束时 `finalizeStreamedMessage` 再统一写回历史。附件点击、删除、预览、自动伸缩和 Shift+Enter 换行都在输入区完成，群聊另有邀请 Agent 发言按钮。

### 5. Topic 列表的渐进呈现

`topicListManager.js` 初始只渲染 40 条 Topic，滚动距离底部 320px 后按 30 条批量追加，并用 `requestAnimationFrame` 分帧；每一行先显示消息数占位符 `...`，由 `IntersectionObserver` 在进入视口前 240px 才读取 history 计算总数/未读标记。行点击切换 Topic，右键打开重命名、删除、标记已读等菜单，搜索模式下禁用拖放排序。这个列表策略与消息区的“整段 DOM 重绘”相互独立：Topic 多时减少首次 IO，消息流中仍直接更新当前气泡。

### 6. 已知呈现边界

- 消息区不是虚拟列表，长 Topic 的初始批量渲染和后续 `redisplayChat` 会带来整段 DOM 成本；
- 单聊与群聊共用发送按钮外观，但中断实现不同（前文已核实），UI 上看不出本地 abort 是否真正生效；
- 三种 presentation mode 只改变布局/样式，工具块、思考链和 DailyNote 的协议解析仍由同一套 renderer 完成。

主要 UI 依据：`main.html`（布局、presentation 选择器、输入区）、`renderer.js`（按钮态/窗口状态/presentation 应用）、`modules/messageRenderer.js`（渲染和事件委托）、`modules/topicListManager.js`（渐进列表和未读计数）、`style.css`。
## 12. UI 交互详查

消息右键由 `modules/renderer/messageContextMenu.js` 提供：流式/思考中的消息显示“中止回复”；完成消息可编辑、复制渲染后的文本、剪切/粘贴（编辑态）、创建分支、转发、助手消息朗读气泡、阅读模式、删除，以及按角色显示“重新回复”。删除有确认对话框，编辑态有保存/取消和文本区。代码/媒体块另有复制、预览和下载。输入区按钮包括新建 Topic、附件、表情包、发送/停止，发送按钮右键打开高级回复菜单；`#messageInput` 明示 Shift+Enter 换行。

左侧 Agent 列表支持搜索、点击切换、创建、编辑和删除；群组可创建并邀请 Agent 发言。当前 Agent 设置中的模型按钮可替换模型，模型参数、上下文上限、流式输出和 TTS 在折叠设置段落中修改。标题栏提供当前 Agent 设置、通知/监控、主题、语音聊天和气泡/统一/刊物 presentation mode；Topic 右键可重命名、删除、标记已读。

## 13. UI 交互再深挖：弹窗、状态反馈与无障碍

### 13.1 弹窗/对话框机制

VCPChat **没有使用任何第三方 Modal 库**，全部自定义实现，有两套分支：

**通用 Modal（`uiHelperFunctions.openModal/closeModal`，`modules/ui-helpers.js:323-360`）**：给目标元素加/移除 `active` class。为节省首屏 DOM，Modal 元素采用 `<template>` 懒加载模式——打开时如果 `document.getElementById(modalId)` 不存在，会从同名 `<template id="...Template">` 克隆到 `#modal-container`，然后派发 `modal-ready` 自定义事件（`:339`）通知各模块绑定事件监听器。模型选择弹窗（`modelSelectModal`）、正则规则弹窗（`regexRuleModal`）和全局设置弹窗（`globalSettingsModal`）均走此路径。打开时调用 `modalElement.focus()`（`:347`），但**没有焦点陷阱（focus trap）**，Tab 键可以离开 Modal 到达背景元素。Esc/遮罩点击关闭需各 Modal 自行绑定（`regexRuleModal` 绑定了遮罩点击，`:736-739`；全局设置弹窗未见 Esc 监听）。

**确认对话框（`uiHelperFunctions.showConfirmDialog`，`modules/ui-helpers.js:889-977`）**：返回 `Promise<boolean>`，用于删除 Agent/群组、删除正则规则等危险操作。动态创建 `.confirm-dialog-overlay` 并附到 `document.body`，`requestAnimationFrame` 后加 `visible` class 触发 CSS 进场动画，确认按钮自动 `focus()`（`:944`）。支持：Esc 取消（`:948`）、Enter 确认（`:951`）、点击遮罩取消（`:959-963`）。`isDanger=true` 时确认按钮加 `danger` class（红色）。关闭时移除 `visible` class，200ms 后从 DOM 移除（`:969-974`）。

**头像裁剪器（`avatarCropperModal`）**：Canvas 实现，支持拖拽移动圆形裁剪框和滚轮缩放（半径范围 30-100px），`modules/ui-helpers.js:460-626`。裁剪完成后用 `canvas.toBlob` 生成 PNG 文件，通过回调传出；事件监听器在关闭时逐一 `removeEventListener` 清理（`:601-608`）。

### 13.2 Toast 与通知侧栏

全部自定义，无系统 `Notification` API 调用，无 Toast 第三方库。有两套并行展示机制（`modules/notificationRenderer.js`）：

**浮动 Toast（`#floating-toast-notifications-container`）**：
- `prepend` 插入，新 toast 在最上方叠加，无数量上限（会随时间自动消失）。
- 默认 **7 秒**自动消失（`:460`）；`tool_approval_request` 类型**永不自动消失**（`:463-465`），须用户点击允许/拒绝后才消失；支持通过过滤规则配置 `duration`（毫秒），`duration=0` 也表示永久（`:467-469`）。
- 点击 toast 本体立即手动关闭（审核类通知例外，`:340-342`）。
- 关闭动画：加 `exiting` class → 监听 `transitionend` 移除 DOM，500ms fallback 强制移除（`:399-413`）。
- 当通知侧栏（`#notificationsSidebar`）处于 `active` 状态时，**抑制浮动 toast**，直接写入侧栏列表（`:449`）。
- 窗口获焦时清理已加 `exiting` 且超过 10 秒的残留 toast（`:517-547`）；每 30 秒定时清理超 15 秒的 toast（`:552-571`）。

**持久侧栏列表**：`<li>` prepend 到 `#notificationsList`，点击淡出 + 右滑消失（`:387-394`），copy 按钮复制原始 JSON；tool_approval_request 项展示允许/拒绝按钮和可选理由文本框（`:278-330`）。

`uiHelperFunctions.showToastNotification`（`modules/ui-helpers.js:367-415`）是面向应用内部的简化版 Toast，支持 `type`（`info/success/error/warning`）和自定义 `duration`（默认 3000ms），写法与上面相同。

### 13.3 主题切换机制

主题切换**不是 CSS 变量热替换**，而是**整窗口重载**：`handleApplyTheme`（`modules/ipc/themeHandlers.js:93-108`）将选中的主题 CSS 文件（`styles/themes/themesXxx.css`）整体覆写到 `styles/themes.css`，然后调用 `mainWindow.reload()`（`:101`）和 `themesWindow.reload()`（`:103`），窗口完整重新加载。

深色/浅色模式通过 Electron `nativeTheme.themeSource` 控制（`:22-38`），可设置 `'light'`、`'dark'` 或 `'system'`，值存入 `settings.json` 的 `currentThemeMode` 字段。系统主题跟随通过监听 `nativeTheme.on('updated')` 实现（`:41-44`, `:207`），变更时向所有窗口广播 `theme-updated` IPC 消息，渲染进程收到后切换 `body.light-theme` class。

CSS 变量约定：`:root` 块定义暗色主题变量，`body.light-theme` 块覆盖亮色变量；每个主题文件同时包含两个块，通过 `themeHandlers.handleGetThemes` 可枚举所有主题及其变量名（`:50-91`）。主题选择器是一个独立的 850×700 无框子窗口（`Themesmodules/themes.html`，`frame: false`，`:169`）。

### 13.4 图片/附件预览——独立窗口而非灯箱

VCPChat 的图片预览**不是内嵌灯箱**，而是打开一个独立 Electron 子窗口（`modules/image-viewer.html`）。触发点：`modules/messageRenderer.js:2613` 调用 `electronAPI.openImageViewer({ src, title, theme })`。

图片查看器功能远超简单灯箱：
- **缩放**：Ctrl+滚轮，范围 `0.05×–32×`（支持极端缩小看长截图全貌）；Shift+滚轮步长更大（`ZOOM_FACTOR_FAST=1.5` vs `ZOOM_FACTOR_STEP=1.15`，`image-viewer.js:54-56`）。
- **拖拽平移**：缩放非 1× 时鼠标左键拖拽；双击重置到 1×（`:450-457`）。
- **绘图工具**：选择、画笔、橡皮、取色器、直线、矩形、圆形、箭头，支持颜色和画笔大小；操作历史最多 50 步撤销/重做（`:47`）。
- **OCR**：按需懒加载本地 `vendor/tesseract.min.js`（`:608-635`），识别简体中文+英文，结果可复制。
- **导出**：复制到剪贴板（原图+绘图叠合）、下载 PNG。
- 右键点击切换工具栏可见性（`:409-413`）。
- 键盘快捷键（仅在查看器窗口内有效）：Esc（切换工具/关闭）；Ctrl+Z/Y（撤销重做）；V/B/E/I/L/R/C/A（切换工具，`image-viewer.js:732-742`）。

图片打开时携带当前主题（`theme` 参数），查看器也监听 `onThemeUpdated` 事件保持同步（`:82-83`）。大 dataURL（如阅读模式截图）通过 token 机制传递避开 URL 长度限制（`:87-101`）。

### 13.5 表情包选择器

`modules/emoticonManager.js`：从服务端 API `getEmoticonLibrary()` 加载表情库，**只筛选当前用户对应的分类**（`"通用表情包"` + `"${userName}表情包"` 两个分类，`:53-59`）。

UI：**平铺图片网格**，没有搜索框，没有分类切换，没有分页（`:85-99`）。面板固定尺寸 270×240px，出现在按钮上方（`:158-165`）；若上方空间不足则移到按钮下方（`:161-163`）。点击面板外部关闭（100ms 延迟绑定，避免立即触发，`:107`）。

点击表情包将 `<img src="..." width="80">` HTML 标签插入到 `textarea.value`（`:131-135`），不是转义后的 Markdown 语法。面板无加载动画——若表情库为空，格内显示"没有找到可用的表情包"占位文字（`:89-90`）。

### 13.6 键盘快捷键清单

**全局快捷键**（Electron `globalShortcut`，应用窗口无焦点时也有效）：
- `Super+Alt+Z`：打开便签（note-mini）窗口（`main.js:1066`）
- `Ctrl+Shift+I`：打开开发者工具（`main.js:1059`）
- `CommandOrControl+Shift+P`：划词助手浮窗（动态注册/注销，`modules/ipc/assistantHandlers.js:724`）

**应用内快捷键**（`modules/event-listeners.js:1461-1523`，仅在主窗口有焦点时有效）：
- `Ctrl/Cmd+S`：快速保存 Agent 设置（仅当设置 tab 激活时，`:1462-1468`）
- `Ctrl/Cmd+E`：快速导出当前 Topic（`:1470-1475`）
- `Ctrl/Cmd+D`：AI 续写当前话题（Flowlock 锁定时会弹 toast 阻止，`:1477-1491`）
- `Ctrl/Cmd+N`：新建话题（已上锁，`:1513-1517`）
- `Ctrl/Cmd+Shift+N`：新建未上锁话题（`:1510-1512`）
- `Shift+Enter`：输入框内换行（非 Shift 的 Enter 直接发送，`:443-444`）

**设置页面鼠标快捷操作**（`modules/settingsManager.js:604-660`）：
- 设置 tab 内双击右键：跳回助手（Agents）页面（300ms 双击检测）
- 设置 tab 内中键点击：跳转到话题（Topics）页面

### 13.7 动画与过渡效果

全部在 `styles/animations.css` 中定义（`style.css` 第 10 行 `@import`）：

**流式输出进行中**：`.message-item.streaming .md-content::after` 用 `vcp-border-flow`（3s linear infinite）在气泡四周绘制流光边框，背景使用 mask 技巧只显示边框区域不遮挡内容（`:123-150`）。在 panel/immersive 模式下改为左侧细轨道 `vcp-stream-activity-rail`（1.8s ease-in-out，高度收缩脉冲）。

**TTS 朗读中**：头像微浮动（`speaking-avatar-float`，3.2s cubic-bezier）+ 旋转光晕边框（`speaking-orbit`，1.8s linear infinite，利用 conic-gradient + mask 实现尾迹效果，`:263-294`）。

**Avatar 反弹**（`avatar-bounce`，0.6s）和**徽章出现**（`badge-appear`，0.4s）在 Flowlock 锁定/解锁时触发。

**已注释的动画**：topic 激活波纹（`st-soft-circular-ripple-effect`）和数字时钟冒号闪烁（`blinkColon`）均已注释掉，注释原因为"减少空闲重绘"。

**Presentation mode 切换**：`renderer.js` 的 `applyChatPresentationMode` 直接替换 `body` 上的 class，**没有专属过渡动画**，是瞬间切换。布局宽度变化由 CSS `transition` 属性承接，但 CSS 中是否有对应 transition 声明未在此次调查中逐一确认。

### 13.8 桌面集成（Electron）

**系统托盘**（`main.js:422-528`）：图标为 `assets/icon.png`，tooltip "VCP AI 聊天客户端"。右键菜单包含：显示/隐藏主窗口、显示/隐藏信息流监听器、打开 VCP 桌面、退出。左键点击切换主窗口显隐（若主窗口已销毁则改为切换 RAG 观测窗口）。macOS 特殊处理：左键切换显隐，右键弹出菜单，不设置 `setContextMenu` 以避免左键也弹菜单（`:510-527`）；macOS 图标调整为 16×16 模板图像适配深浅色菜单栏（`:431-434`）。关闭主窗口时若桌面模式（Desktop 窗口）处于活跃状态，主窗口隐藏到托盘而非退出（`:362`）。

**全局快捷键**：见 13.6 节。

**语音聊天窗口**（`Voicechatmodules/voicechat.html`，`voicechat.js`）：独立子窗口，初始 `inputMode='text'`，点击切换按钮（`toggleInputModeBtn`）在文本模式和语音模式之间切换（`:55`, `:311-320`）。语音模式使用语音识别（browser speech API 或外部识别器），有 3 秒无语音超时（`SPEECH_TIMEOUT_DURATION=3000`，`:58`）。关闭窗口时自动将本次对话历史保存为当前 Agent 的一个新 Topic（`:131-163`），并尝试调用话题自动总结。audioContext 在首次用户手势时初始化（`:14-23`），避免浏览器自动播放限制。

**系统通知**：未在主进程或渲染进程中发现 `new Notification(...)` 或 Electron `Notification` 类调用——应用**不发送系统桌面通知**，所有 AI 消息通知通过右侧内置通知侧栏和浮动 Toast 呈现。

### 13.9 侧栏宽度与 Compact 导航

**侧栏可拖拽宽度**：调整逻辑在 `modules/uiManager.js:48-130`。最小/最大宽度**从 CSS 的 `computed.minWidth` / `computed.maxWidth` 动态读取**，代码中仅提供 180px 作为 fallback（左侧栏和右侧通知栏均为 180px，`:93`, `:98`），最大宽度 fallback 600px（`:57`）。拖拽过程中通过 `requestAnimationFrame` 节流更新，拖拽时禁用元素 `transition` 以避免卡顿（`:88`）。

**Compact navigation 触发条件**：不是基于窗口宽度自动触发，而是**由 `settings.sidebarAvatarOnly` 字段控制**（`renderer.js:1560`）——用户在侧栏宽度设置中主动开启后生效。avatar-only 模式下侧栏折叠为仅显示头像，展示 `.sidebar-compact-navigation` 悬浮菜单。点击菜单项中的 Topics 触发 `leftSidebar.classList.add('compact-topics-open')`，话题列表以抽屉形式叠加显示（`uiManager.js:382-386`）；Esc 键关闭抽屉（`:451`）；点击话题项后自动关闭抽屉（`:439-441`）。

### 13.10 全局设置面板分区

`modules/global-settings-manager.js` 的 `handleSaveGlobalSettings` 函数（`:38-106`）揭示全局设置面板涵盖以下字段分区：

- **用户信息**：用户名、头像（含裁剪）、头像边框色、名称文字色、是否跟随主题色
- **VCP 服务器**：`vcpServerUrl`（失焦自动补全路径）、`vcpApiKey`、`vcpLogUrl`、`vcpLogKey`、`fileKey`
- **话题总结**：`topicSummaryModel`（可从模型选择弹窗挑选）
- **聊天外观**：Presentation mode 单选、宽布局开关、气泡最大宽度（分默认/通知侧栏打开/窄侧栏等场景）、字体预设（正文/代码/日记/工具四类，支持自定义字体名）
- **流式体验**：`enableSmoothStreaming`、`minChunkBufferSize`、`smoothStreamIntervalMs`
- **功能开关**：`enableAgentBubbleTheme`（Agent 自定义气泡主题）、`enableAiMessageButtons`、`enableRegenerateConfirmation`
- **中键快捷操作**：启用/禁用、action 类型、高级中键（长按延时）
- **语音模式**：local（SoVITS URL/Key）vs network（provider URL/Key），语音识别浏览器路径、识别页面路径
- **AI 续写**：续写 prompt、Flowlock 续写延迟秒数
- **助手 Agent**：划词助手绑定的 Agent 下拉选择
- **笔记路径**：多条网络笔记路径输入
- **分布式服务器**：启用开关
- **Rust 助手**（划词监听）：规则模式（whitelist/blacklist/none）、关键词列表、截图应用列表、自定义阈值

### 13.11 无障碍现状（如实记录）

**已有 ARIA 标注的区域**：
- Presentation mode 切换器（`main.html:47-53`）：`role="radiogroup"` + `aria-label="聊天显示模式"`，各按钮有 `role="radio"` 和 `aria-checked`
- 侧栏 tabs：`role="tablist"` + `aria-label="Sidebar sections"`，tabpanel 有 `aria-hidden`
- Compact navigation：`aria-label="窄侧栏导航"`，trigger 按钮有 `aria-label`，menu 项有 `role="menuitem"`
- 设置区各折叠按钮：有 `aria-label="展开或收起xxx"` （`main.html:239`, `:374`, `:394` 等）
- 所有 SVG 图标：普遍标注 `aria-hidden="true"`
- 通知侧栏复制按钮的 SVG：有 `aria-hidden="true"`

**缺失 ARIA 标注的区域**（经代码检查确认未见）：
- Agent 列表 `<li>` 和群组列表 `<li>`：无 `aria-label`，无 `role`
- Topic 列表 `<li>`：无 `aria-label`
- 消息列表 `.message-item`：无 `role="listitem"` 或 `aria-label`
- 发送按钮在"中止回复"模式下动态替换 SVG，但 `data-mode` 切换未见对应 `aria-label` 更新

**焦点管理**：确认对话框打开时确认按钮自动 `focus()`（`:944`）；通用 Modal 打开时调用 `modalElement.focus()`（`:347`），但无 focus trap——Tab 键可以穿透到背景。无键盘导航在 Agent/Topic 列表中的支持（列表项无 `tabindex`）。

总体评估：核心功能控件有基础 ARIA，但主要内容区（消息列表、Agent/Topic 列表）缺乏语义标注，键盘可达性不完整，无障碍支持处于初步阶段。
