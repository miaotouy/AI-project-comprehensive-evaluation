# NextChat 对话请求与上下文调查笔记

> 调查对象：`E:\works\git\NextChat`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`defdcdb55d850cd12c4c657eb83729fd66e215c0`（分支：`main`）
>
> 调查方式：从 [`../Chat/NextChat-Chat调查笔记.md`](../Chat/NextChat-Chat调查笔记.md)（2026-08-06 调查）迁移现有段落与证据，未重新调查代码
>
> 调查范围：客户端提交入口（onUserInput）、上下文拼装顺序、短期窗口与摘要压缩、provider adapter 交接、SSE 流式回调、停止/重试与 MCP 回注；会话数据语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

NextChat 的生成任务完全在浏览器客户端编排：

1. `onUserInput` 先填充模板和多模态图片，再创建 user 消息 + `streaming: true` 的 assistant 占位。
2. 请求按 system prompt → 长期摘要 → Mask context → 短期历史 → 新用户消息的顺序组装（`getMessagesWithMemory`）。
3. 占位消息经 SSE 回调原地更新；工具调用由 provider adapter 执行并重新请求，MCP 结果以特殊用户消息再进入 `onUserInput`。
4. 长对话两级压缩：`historyMessageCount`/`max_tokens` 管短期窗口，`memoryPrompt` 管超过阈值后的摘要；首次达到 50 个估算词时单独生成会话标题。
5. 停止/重试走 `ChatControllerPool`；无服务端任务状态。

## 系统边界与生成任务主链

```text
Chat 输入 -> doSubmit -> useChatStore.onUserInput
   -> fillTemplateWith + multimodal images
   -> getMessagesWithMemory
      system -> long memory -> Mask.context -> recent history -> user
   -> 保存 user message + streaming assistant placeholder
   -> getClientApi(provider).llm.chat
      -> SSE onUpdate / onBeforeTool / onAfterTool / onFinish
   -> updateTargetSession
   -> onNewMessage -> 统计、MCP 检测、自动标题/摘要
```

边界：占位消息与 `tools`/`memoryPrompt` 的持久化形状属于会话与消息管理（`../会话与消息管理/NextChat-会话与消息管理调查笔记.md`）；发送/停止按钮、loading 与流式动画的工作流属于 Chat UI（`<../Chat UI/NextChat-ChatUI调查笔记.md>`）；流式文本的 rAF 动画与 Markdown 渲染属于消息渲染器（`../消息渲染器/NextChat-消息渲染器调查笔记.md`）。

## 1. 提交入口、任务对象与状态机

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

占位消息的数据模型（streaming/isError/tools 字段）见会话与消息管理笔记 §1。

## 2. 历史选择与上下文拼装顺序

`getMessagesWithMemory`（`app/store/chat.ts:542-639`）先生成可选 system prompt：对 GPT/ChatGPT 模型，如果启用 `enableInjectSystemPrompts`，把默认 system template 与 MCP 工具目录合并；只有 MCP 时也会单独发送 MCP system prompt。

随后按以下顺序构造 `recentMessages`：

```text
0. system prompt
1. long-term memory：memoryPrompt（可选）
2. Mask.context：预置示例消息
3. short-term history：从最后一条向前读取
4. 当前 user message（由 onUserInput 追加）
```

短期窗口同时受 `historyMessageCount` 和 `max_tokens` 估算限制；错误消息不会进入历史。`clearContextIndex` 会把可用起点抬高，所以能在不删除 UI 历史的情况下停止发送更早消息和摘要（其数据语义见会话与消息管理笔记 §4）。

## 3. 预算、截断、摘要与压缩

- **短期窗口**：`historyMessageCount`/`max_tokens` 由 `estimateTokenLength` 估算限制（§2）。
- **摘要压缩**：摘要流程从 `lastSummarizeIndex` 或 `clearContextIndex` 开始，过滤错误消息；若估算长度超过 `max_tokens`，只保留最近 `historyMessageCount` 条。超过 `compressMessageLengthThreshold` 且 `sendMemory` 为 true 时，追加"总结" system prompt，并使用配置的压缩模型或 `getSummarizeModel`（`app/store/chat.ts:727-795`）。成功后把返回文本写入 `memoryPrompt`，并把 `lastSummarizeIndex` 更新到当前消息长度。
- **自动标题**：`summarizeSession` 在 `enableAutoGenerateTitle` 开启、topic 仍是默认值且估算消息长度达到 50 时，取最近的 `historyMessageCount` 条消息，加上 topic 提示词，使用非流式请求生成标题（`app/store/chat.ts:685-725`）。
- **触发点**：`onNewMessage` 在每次成功 assistant 消息后依次更新统计、检测 MCP JSON、调用 `summarizeSession(false, targetSession)`（`app/store/chat.ts:394-405`）。
- **不可逆性**：摘要失败时只记录错误，不删除原始消息——"保留完整本地历史、请求只带摘要和最近窗口"（持久化形状见会话与消息管理笔记 §7）。

## 4. SDK、Provider、模型与协议交接

- `getClientApi(providerName).llm.chat` 是 provider adapter 的接管点；SSE 回调在该调用中产生。
- 普通插件工具由 provider adapter 执行并重新请求；MCP 结果以特殊用户消息再进入 `onUserInput`（`isMcpResponse` 标记）。
- 具体 provider payload 字段由各 adapter 生成，本次未展开（协议层细节属于 LLM 渠道管理类目）。
- 服务端 `/api/config` 只提供能力探测（`Home` 启动时 fetch），不保存会话（会话持久化见会话与消息管理笔记 §2）。

## 5. 流式事件、缓冲、节流与顺序

- 流式文本的逐帧动画（`requestAnimationFrame` + `remainText`）在 `app/utils/chat.ts`，是渲染层行为，见消息渲染器笔记 §4；本类目只记录 store 层的状态转换（§1 回调表）。
- 占位消息原地更新，不新建消息节点；顺序保证依赖 SSE 单连接顺序，未实现服务端重连与断点续传（未验证）。

## 6. 完成、异常、半截流与最终回写

- 完成：`onFinish` 写入最终内容/date、转为非 streaming、触发 `onNewMessage`（统计、MCP 检测、标题/摘要，§3）。
- 异常：`onError` 把错误对象格式化追加到 assistant.content，设置 user/assistant 错误标记并回收 controller（`app/store/chat.ts:459-527`）。
- 半截流：连接关闭或 `[DONE]` 后一次性收尾（`app/utils/chat.ts:197-220`、`423-446`，动画细节在消息渲染器笔记 §4）。
- 回写对象：始终是当前 session 的占位消息（`updateTargetSession`），不产生额外任务对象。

## 7. 停止、重试、续写与重新生成

- **停止和重试**使用 `ChatControllerPool`，controller 在 `onController` 中注册；聊天页的 Stop action 调用 `ChatControllerPool.stop`（`app/store/chat.ts:519-526`，入口见 Chat UI 笔记 §4）。
- **重试**：错误标记的消息上触发重新发送（入口见 Chat UI 笔记 §5）；重试的起始上下文选择（是否复用 `clearContextIndex` 起点）本次未展开。
- **续写**：源笔记未覆盖独立的"继续生成"执行链，本次未调查。

## 8. 队列、多会话并发与后台生成

- 每次提交都走 `onUserInput`，无独立发送队列；同一会话多次提交与多会话并发的执行语义未验证（store 按 session 数组组织，无并发锁证据）。
- MCP 回注（特殊用户消息再进入 `onUserInput`）是唯一的"二次提交"通道（§4）。
- 后台生成：无服务端任务，窗口关闭即停止（未验证）。

## 9. Agent、工具、知识库与附件注入点

- 工具目录：system prompt 合并 MCP 工具目录（§2，`enableInjectSystemPrompts` 时）。
- 工具执行：普通插件工具由 provider adapter 执行并重新请求（§4）。
- 附件：图片与文本合并为多模态数组进入请求（§1 第 3 步）；`audio_url` 等消息字段的播放由渲染器处理。
- 知识库/联网：本次迁移范围内未发现独立的知识库注入点（源笔记未覆盖），不虚构。

## 10. 退出恢复、日志与已确认边界

- 已确认边界：本地无服务端 runtime，所有任务状态在浏览器内存 + IndexedDB；源笔记未覆盖任务日志/trace 的可观测性证据。
- 退出/刷新时正在进行的请求如何处理（controller 是否在 unload 中止）本次未调查。
- 同步相关的合并缺陷见会话与消息管理笔记 §6。

## 11. 未验证事项

- 停止按钮的网络级 abort 效果未验证（`ChatControllerPool.stop` 只是 controller 层接口）。
- 摘要与标题的模型输出质量、截断未验证；token 估算为启发式。
- 多会话并发、退出恢复、MCP 回注的重复提交边界未运行验证。
- 未运行项目测试或浏览器交互测试；结论来自 commit `706a18b` 的源码。

## 12. 关键源码索引

- 输入、流式回调和工具状态：`app/store/chat.ts:407-527`
- system/context/memory 拼接：`app/store/chat.ts:542-639`
- 自动标题和摘要：`app/store/chat.ts:661-797`（触发点 `:394-405`）
- MCP JSON 回注：`app/store/chat.ts:826-855`
- 停止/重试 controller：`app/store/chat.ts:519-526`
- 流式文本动画（渲染侧）：`app/utils/chat.ts:197-220`、`423-446`
