# SillyTavern 对话请求与上下文调查笔记

> 调查对象：`E:\works\git\SillyTavern`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8`（分支：`release`）
>
> 调查方式：从 [`../Chat/SillyTavern-Chat调查笔记.md`](../Chat/SillyTavern-Chat调查笔记.md)（2026-08-07 调查）迁移现有段落与证据，未重新调查代码
>
> 调查范围：一次生成任务的提交入口、历史筛选与上下文拼装、截断、provider 交接、slash command 拦截、正则分层、宏替换与 Quick Reply 介入点、群聊重新生成；数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

SillyTavern 的一次生成由 `Generate()`（`public/script.js:4231`）统一入口驱动，slash command 可以在真正调用生成 API 之前**整体劫持发送流程**：

- 主链：`sendTextareaMessage()` → `Generate()` → 历史筛选（`is_system` 排除 + 工具 system 例外）→ 角色/名称/continue 状态转换 → system/character/world-info/injection 组装 → generation interceptors → World Info 注入 → `finalPrompt` 或 `oaiMessages` → 按 API 类型生成 `generate_data` 并发送。
- **slash command 拦截点位于生成函数最前面**：`Generate()` 在调用 API 前执行 `processCommands()`，若被判定为"打断"，本次 Generate 直接短路返回，不会有任何生成请求发出。
- **正则替换按位置分层**：不带标记的脚本在 `cleanUpMessage()` 里应用并**结果写回 `chat[messageId].mes` 持久化**；`markdownOnly` 只影响显示；`promptOnly` 只在构建 prompt 时生效（调用点未核实）。
- 宏替换嵌入存储、展示、prompt 构建三处不同代码路径，不是一次性统一处理。
- Quick Reply 用 `makeFirst` 抢占消息渲染事件，插在事件分发链最前面。
- 群聊"重新生成"与单聊"swipe"是两套机制：群聊靠 `extra.gen_id` 分组 + 物理删除尾部消息。

## 系统边界与生成任务主链

```text
sendTextareaMessage()（script.js:1705）
  -> Generate()（:4231）
      -> processCommands()（:3066-3074）：slash command 拦截，可短路返回
      -> 历史筛选：is_system 排除（tool_invocations 例外）
      -> 消息按角色/名称/continue 状态转换（:4442-4505、:4711-4775）
      -> system/character/world-info/injection 组装
      -> generation interceptors（:4505）-> World Info 注入（:4565、:4686）
      -> finalPrompt / oaiMessages（按当前 API 的 prompt/message formatter）
      -> generate_data（:5190-5244，按 API 类型分支）-> 流式/非流式请求（:5268-5334、:5390）
```

边界：`chat[]` 与 JSONL 的数据语义在会话与消息管理；`StreamingProcessor` 的流式 DOM 更新、正则 `markdownOnly` 渲染层、宏第 0 条渲染特例在消息渲染器笔记；swipe/Swipe Picker 等用户工作流在 Chat UI。

## 1. 提交入口、任务对象与状态机

- `public/script.js:1705` 的 `sendTextareaMessage()` 进入 `Generate()`（`:4231`）。
- `sendMessageAsUser()`（`:5815`）创建用户 `ChatMessage`，基础字段在 `:5818-5827`，token count 在 `:5830`，bias 在 `:5838-5841`，附件在 `:5843`，随后写入内存 `chat`（`:5848-5861`）。
- assistant 回复由 `saveReply()`（`:6583`）创建，正文和 metadata 在 `:6684-6701`，swipes 在 `:6740-6767`。
- `Generate()` 在 `:5190-5244` 根据 API 类型生成 `generate_data`，`:5268-5334` 发送流式请求或 OpenAI 请求，`:5390` 处理非流式请求；请求入口按 Kobold、TextGen、Novel、OpenAI 等分支选择不同 payload builder。

## 2. 历史筛选与上下文拼装顺序

- `Generate()` 约 `:4437` 先把 `is_system` 消息排除，只有启用工具且带 `extra.tool_invocations` 的 system 消息保留。
- 之后每条消息按角色、名称、continue 状态和 prompt 格式转换（`:4442-4505`、`:4711-4775`），并分别进入 text completion 或 `setOpenAIMessages` 的 messages 结构。
- system/character/world-info/injection 等内容在 `Generate()` 组装到 prompt 或 OpenAI messages；工具 system 消息通过上述 `tool_invocations` 例外进入。
- 附件先保存在消息的 `extra`/chat metadata，再由对应生成分支决定如何表达；不同 API 模式并不共享完全相同的 payload。

## 3. 预算、截断与压缩

- 构建完成后，SillyTavern 先运行 generation interceptors（`:4505`），再执行 World Info 注入（`:4565`、`:4686`），最后按当前 API 的 prompt/message formatter 生成 `finalPrompt` 或 `oaiMessages`。
- 本次确认了筛选和注入顺序，但**未完整核对**每种后端的 token budget 截断算法（原调查边界）。

## 4. Provider、模型与协议交接

- 请求入口按 Kobold、TextGen、Novel、OpenAI 等分支选择不同 payload builder（第 1 节）；`Generate()` 是唯一的统一入口。
- 流式与非流式各走独立分支；最终 payload 与各后端差异未逐一展开（原调查边界）。

## 5. slash command 对发送流程的介入

slash command 不是"外围工具"，而是**直接嵌入在发送主链最前面的判断点**：

```js
// script.js:4251-4258
if (!(dryRun || depth || type == 'regenerate' || type == 'swipe' || type == 'quiet')) {
    const interruptedByCommand = await processCommands(String($('#send_textarea').val()));
    if (interruptedByCommand) { unblockGeneration(type); return Promise.resolve(); }
}
```

`processCommands()`（`script.js:3066-3074`）判断输入框内容是否以 `/` 开头，是的话整段交给 `executeSlashCommandsOnChatInput()` 执行，且**如果被判定为"打断"，本次 Generate 直接短路返回，不会有任何生成请求发出**。任何用户输入只要触发 slash command 解析，就完全绕开了模型调用——命令解析发生在生成函数内部的最前面，是决定"这次发送到底要不要变成一次生成请求"的判断点。

## 6. 正则分层与生成后文本清洗

`extensions/regex/engine.js:334-374`（`getRegexedString`）：每个正则脚本可标记 `markdownOnly`/`promptOnly`，三者互斥生效：

- 不带任何标记的脚本：在 `cleanUpMessage()`（`script.js:6422`，流式/非流式生成收到文本后都会走这里）里被应用，**结果直接写回 `chat[messageId].mes`，会持久化进聊天文件**；
- `markdownOnly` 脚本：只在 `messageFormatting()`（`script.js:1809-1813`，渲染时调用）里生效，**只影响显示 HTML，从不写回 `chat[]` 或存盘**（渲染细节在消息渲染器笔记）；
- `promptOnly` 脚本：只在构建发给模型的 prompt 时生效（**未核实**其确切调用点，从 `regex_placement.SLASH_COMMAND`/`WORLD_INFO` 等枚举值可推断存在专门的 prompt 组装阶段调用）。

## 7. 宏替换：三处不同代码路径

`substituteParams()`（`script.js:2922` 定义）在 `sendMessageAsUser`（`5816, 5823`，用户消息发送时替换 `USER_INPUT` 位置的宏）、`messageFormatting`（`1761`，但只对**第 0 条消息**在渲染时懒替换——该渲染特例在消息渲染器笔记）、`power_user.user_prompt_bias` 处理（`1780, 6401`）等多处独立调用，不是一次性统一处理。

## 8. Quick Reply 介入点：`makeFirst` 抢占事件

`extensions/quick-reply/index.js:275, 282, 292`：

```js
eventSource.on(event_types.CHAT_CHANGED, ...)                                    // 切换聊天时重载该角色的 QR 集合
eventSource.makeFirst(event_types.USER_MESSAGE_RENDERED, ...onUserMessage...)     // 用户消息渲染后自动触发
eventSource.makeFirst(event_types.CHARACTER_MESSAGE_RENDERED, ...onAiMessage...)  // 角色消息渲染后自动触发
```

`makeFirst` 意味着 Quick Reply 的自动化钩子会**在其它同事件监听器之前**执行，如果自动回复规则命中，可能在其它扩展还没处理完当前消息前就已经发起了下一轮生成——Quick Reply 不是"外挂在消息发完之后"的旁路功能，而是插在事件分发链最前面的强介入点。

## 9. 群聊重新生成：`gen_id` 分组

`regenerateGroup()`（`group-chats.js:167-188`）靠比较 `lastMes.extra.gen_id` 是否等于本轮 `generationId` 来决定要删掉几条尾部消息重新生成（`gen_id` 的数据语义见会话与消息管理笔记 6）——单聊靠 `swipes` 数组保留候选，群聊靠 `gen_id` 分组 + 物理删除消息重新触发。

## 10. 设计取舍与已确认边界

- **四个扩展介入点分属四个不同生命周期节点**：发送前拦截（slash command）、生成后文本清洗（正则-非markdown）、渲染时格式化（正则-markdown + 宏第0条特例）、渲染完成后自动化（Quick Reply）——不是单一的"扩展系统"统一调度。
- **流式期间的扩展 hook 时序**：`CHARACTER_MESSAGE_RENDERED`/`MESSAGE_RECEIVED` 事件只在流结束时 emit 一次，不随每个 token 触发（该事实属于渲染侧，记录在消息渲染器笔记，这里只记其对请求侧的影响：依赖这些事件做二次处理的扩展在流式期间不会收到中间态）。
- **工具调用场景下"流式结束"与"生成流程结束"是两个时间点**：`finalizeIntermediaryMessage({unlockUI:false})`（`script.js:5357`）先把消息落盘但不解锁输入框，`streamingProcessor = null` 可能被延后到工具调用结果处理完之后（`script.js:5369/5373/5382`）。
- 停止、重试、队列与后台任务的执行语义在原调查中未深入（未虚构）。

## 11. 未验证事项

- `promptOnly` 正则脚本的具体调用点（只从枚举值推断存在，未定位到调用代码）。
- 每种后端的 token budget 截断算法。
- 各扩展 regex 的 `promptOnly` 作用域及完整截断细节。
- 停止/重试的执行链路未逐行核对。

## 12. 关键源码索引

- `public/script.js`：`Generate()`（4231-4262）；`processCommands`（3066-3074）；`sendTextareaMessage`（1705）；`sendMessageAsUser`（5815-5864）；`saveReply`（6583-6770）；`cleanUpMessage`（6422）；`substituteParams`（2922）；`finalizeIntermediaryMessage` 工具调用收尾（5357-5382）
- `public/scripts/extensions/regex/engine.js`：`getRegexedString`（334-374）
- `public/scripts/extensions/quick-reply/index.js`：事件绑定（258-297）
- `public/scripts/group-chats.js`：`regenerateGroup`（167-188）
