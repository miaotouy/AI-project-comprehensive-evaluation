# SillyTavern 对话请求与上下文调查笔记

> 调查对象：`https://github.com/SillyTavern/SillyTavern`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`06bde939fb1e9c4c8d8641d810f0a916b5bce127`（分支：`release`）
>
> 调查方式：直接阅读源码（`public/script.js` 的 `Generate()` 主链、正则引擎、slash command 执行器、群聊生成包装器、OpenAI 消息组装），逐段核对当前 HEAD 的执行顺序与分支
>
> 调查范围：一次生成任务的提交入口、历史筛选与上下文拼装顺序、token 预算与截断、provider 交接与流式事件链、完成/异常/停止/重试/续写的收口语义、群聊串行生成、外部能力（World Info、Data Bank、工具、正则、宏、Quick Reply）注入点；数据对象语义与界面工作流分别进入会话与消息管理、Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

SillyTavern 的一次生成由 `Generate()`（`public/script.js:4290`）统一入口驱动，slash command 可以在真正调用生成 API 之前整体劫持发送流程：

- 主链：发送入口把输入交给统一生成入口后，一次请求依次经过历史筛选、逐条消息的正则与附件处理、角色字段与 system prompt 拼装、World Info 扫描注入、生成 interceptors、按 API 类型组装 text completion 或 OpenAI messages、token 预算裁剪，最后发出请求，以流式收尾或 `saveReply` 写回，再调用 `saveChatConditional()` 落盘。
- **slash command 在生成入口前段拦截普通输入**：入口先补全角色数据并发布 GENERATION_STARTED，再处理输入中的命令；命中打断时在真正调用模型 API 前短路。dryRun、递归 depth、regenerate、swipe 与 quiet 路径跳过该命令处理（`public/script.js:4290-4321`）。
- **正则按用途分层**：无标记脚本在生成后清洗与 prompt 组装两处都生效，清洗结果经 `cleanUpMessage` 写回 `chat[].mes` 持久保存；`markdownOnly` 只影响显示层，`promptOnly` 只在 prompt 组装时生效。分层定义见 `public/scripts/extensions/regex/engine.js:334-381`，prompt 侧的调用点在 `public/script.js:4447`。
- **宏替换不是一次性统一处理**：`substituteParams()` 在用户消息发送、首条消息渲染、user prompt bias、quiet prompt、正则替换等多个代码路径独立调用。
- Quick Reply 用 `eventSource.makeFirst` 抢占 `USER_MESSAGE_RENDERED`/`CHARACTER_MESSAGE_RENDERED` 事件，插在事件分发链最前面。
- 群聊"重新生成"与单聊"swipe"是两套机制：群聊靠 `extra.gen_id` 分组 + 物理删除尾部消息；群聊内多个成员串行生成，由 `generateGroupWrapper` 循环驱动。

## 系统边界与生成任务主链

```text
sendTextareaMessage()（script.js:1705；#send_but 经 SimpleMutex 进入，11099-11102）
  -> Generate()（script.js:4290）
      -> 补全角色数据，再发布 GENERATION_STARTED（4295-4299）
      -> 普通输入路径 processCommands()（4310-4318）：命令打断时短路；dryRun/depth/regenerate/swipe/quiet 跳过
      -> GENERATION_AFTER_COMMANDS（4321）；后续群聊分支转 generateGroupWrapper
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

- **入口**：发送入口 `sendTextareaMessage()` 只在三个前置条件同时成立时继续：`swipeState` 为 `NONE`、没有发送正在进行、当前没有 slash command 在执行。"继续生成"开关（`power_user.continue_on_send`）打开且输入框为空、最后一条消息来自角色时，本次发送被改判为续写类型。发送按钮外面再包一层互斥锁，连点会被串行化。条件判断与类型改写见 `public/script.js:1705-1740`，按钮绑定在 11099-11102。
- **任务对象**：生成状态由一组模块级变量共同表达，没有独立的任务或请求对象：
  - `is_send_press`：生成锁；
  - `abortController`：当前请求的中止句柄；
  - `streamingProcessor`：流式消费者实例；
  - `swipeState` 与 `chat_metadata.tainted`：swipe 进度与聊天脏标记，后者在非 dryRun 时置真。

  这些变量集中定义在 `public/script.js:455-602`；两个事件成对出现，`GENERATION_STARTED`（4240）与 `GENERATION_AFTER_COMMANDS`（4262），slash command 短路时只发前一个。
- **用户消息**：用户消息先过正则，再做宏替换，然后写入 `chat`，并依次发出 `MESSAGE_SENT` 与 `USER_MESSAGE_RENDERED`；只有 bias 没有正文的消息改走系统消息通道。主流程见 `public/script.js:5815-5864`，bias 分支在 4390-4393。
- **回复消息**：`saveReply()` 按消息类型决定落盘方式：
  - `normal`：新建一条消息；
  - `swipe`：复用最后一条消息的 swipes 槽位；
  - `append`、`continue`、`appendFinal`：往已有正文后面追加。

  群聊消息还会额外记录 `force_avatar`、`original_avatar` 与 `extra.gen_id` 三个字段，最后一个用于标记批次归属。分支实现见 `public/script.js:6583-6771`，群聊字段在 6708-6717。

## 2. 历史选择与上下文拼装顺序

按 `Generate()` 内的实际顺序：

1. **筛选**：隐藏消息（`is_system`）先从历史数组里滤掉；带 `extra.tool_invocations` 的 system 消息在工具调用启用时例外保留。判定见 `public/script.js:4437`。
2. **逐条处理**：逐条消息按角色取用户输入或 AI 输出的正则位点，以 prompt 模式跑一遍正则；同时展开附件文件文本，并把媒体标题与 `extra.append_title` 拼回正文。三段逻辑都在 `public/script.js:4444-4463`。
3. **reasoning**：从最新一条往回遍历，给每条消息补上 reasoning 前缀，过程中按 REASONING 位点跑正则；群聊只处理当前正在生成的角色。实现见 `public/script.js:4472-4498`，群聊分支在 4478。
4. **角色字段**：角色卡里的描述、性格、场景、示例对话、system 与 jailbreak 等字段统一取出；角色卡与群聊的 depth prompt 作为 extension prompt 注入。字段收集见 `public/script.js:4401-4427`。
5. **World Info**：先构造一份名称加正文、顺序反转的扫描输入，再调用 `getWorldInfoPrompt` 扫描，命中结果按 before/after/depth/example/outlet 五种位置注入 extension prompts；非 dryRun 时还会发出 `WORLD_INFO_ACTIVATED`。主流程见 `public/script.js:4565-4622`，事件位置在 `public/scripts/world-info.js:900-903`。
6. **系统提示**：text completion API 的系统提示取自 `power_user.sysprompt`，拼接时走宏替换或 `baseChatReplace`；继续生成时 jailbreak 提示被插到倒数第二条消息之前。两处逻辑见 `public/script.js:4627-4638` 与 4696-4704。
7. **story string**：按 before/after anchor 与各字段模板渲染成文，配置为 `IN_CHAT` 位置时随消息注入；`doChatInject` 负责按配置做 chat 注入。见 `public/script.js:4640-4676`，chat 注入在 4684-4687。
8. **角色转换**：text completion 由 `formatMessageHistoryItem` 转换，instruct 模式下给每条消息补首尾序列；OpenAI 由 `setOpenAIMessages` 组装，负责 narrator 转 system、名称前缀策略以及媒体、工具调用与 reasoning 签名的处理。前者见 `public/script.js:4708-4777`，后者见 `public/scripts/openai.js:561-640`。
9. **组合**：`getCombinedPrompt` 把 story string、示例对话、聊天记录和最后一行（角色名、quiet prompt 或 bias）拼成 `finalPrompt`；拼装前后分别发出 `GENERATE_BEFORE_COMBINE_PROMPTS` 与 `GENERATE_AFTER_COMBINE_PROMPTS`，扩展可以借此整体替换 prompt。事件与位置见 `public/script.js:5073-5185`。

## 3. 预算、截断、摘要与压缩

- **预算**：可用 prompt 预算等于上下文上限减去回复预留；text completion 侧由 `getMaxPromptTokens` 相减得出，OpenAI 侧直接读设置里的上下文与输出上限。见 `public/script.js:5922-5928` 与 `public/scripts/itemized-prompts.js:181`。
- **text completion 截断**：从最新一条往回逐条累计 token，超预算即停止，注入消息先预分配名额；示例对话在剩余预算内补足。拼好后仍超限时，`checkPromptSize` 先丢示例再丢最旧消息，递归重试。实现见 `public/script.js:4814-4868`，示例补位与递归裁剪在 4898-4911 与 5034-5060。
- **OpenAI 截断**：`ChatCompletion` 在 `prepareOpenAIMessages` 里设置 token 预算，`populateChatCompletion` 按预算装填；连必选 prompt 都放不下时抛出 `TokenBudgetExceededError`，并提示 "Raise your token limit"。两处都在 `public/scripts/openai.js:1558-1587`。
- **World Info 预算**：扫描入口 `checkWorldInfo` 接收上下文上限，并按世界书预算与预算上限两个设置控制扫描量和注入量。见 `public/scripts/world-info.js:4597`。
- **摘要/记忆**：记忆扩展输出与作者注释分别占据 `1_memory`、`2_floating_prompt` 两个扩展 prompt 槽，随拼装进入请求，并记录在 itemized prompts 里；记忆压缩与总结本身由 memory 扩展负责。记录点见 `public/script.js:5285-5288`。
- 截断不可逆：被裁剪的历史不会回填，也没有"重新生成时扩大预算"的机制。

## 4. Provider、模型与协议交接

- **协议 Adapter 的接管点**：请求发出前，`Generate` 按 `main_api` 的当前取值选分支，为每种后端构造一份请求数据（`generate_data`）。分支判定见 `public/script.js:5190-5257`，各分支的数据构建函数如下：
  - Kobold：`getKoboldGenerationData`；
  - TextGen：`getTextGenGenerationData`；
  - Novel：`getNovelGenerationData`；
  - OpenAI：`prepareOpenAIMessages`。
- **发送**：请求按流式与非流式两条路径分发，入口在 `public/script.js:6057-6105`。
  - 流式路径按后端分别调用：
    - `sendOpenAIRequest`（OpenAI）
    - `generateTextGenWithStreaming`（TextGen）
    - `generateNovelWithStreaming`（Novel）
    - `generateKoboldWithStreaming`（Kobold）
  - 非流式 `sendGenerationRequest`：OpenAI 走 `sendOpenAIRequest`，Horde 走 `generateHorde`，其余后端用 `fetch` 打到 `getGenerateUrl` 给出的地址。
- **网络路径**：浏览器的请求先打到 SillyTavern 服务端的代理端点，再由服务端转发给外部 provider 并透传流式响应。端点地址由 `getGenerateUrl` 生成（`public/script.js:6113-6126`），转发在 `src/endpoints/backends/text-completions.js:272`；中止请求同样经服务端转发到 `/api/extra/abort`（同文件 89 行）。
- **模型与参数**：模型选择和采样参数都来自前端的模块级设置，服务端只做代理转发，不参与 prompt 语义。text-completions 后端本次没有找到 fallback 或重试逻辑（搜索 `retry` 无命中），Horde 则会在生成前对上下文长度做自适应调整。见 `public/script.js:4516-4528`。

## 5. 流式事件、缓冲、节流与顺序

- **流式消费**：`StreamingProcessor` 的 `generate()` 逐段消费生成器返回的内容；每收到一段，`onProgressStreaming` 先交给 `cleanUpMessage` 清洗（截断 stopping strings、跑正则），再把文本写进当前消息与 DOM，swipe 与 continue 类型还会同步回对应的 swipe 槽位。消费入口见 `public/script.js:3481`，分段处理在 3584-3685。
- **顺序保证**：文本按到达顺序追加，无并发缓冲队列；`stream_fade_in`/`streaming_fps` 是渲染侧节流（渲染器笔记）。
- **事件时机**：`MESSAGE_RECEIVED` 与 `CHARACTER_MESSAGE_RENDERED` 只在流正常结束或错误收尾时各发一次，不随 token 触发；swipe、impersonate、continue 的错误收尾不发事件。`MESSAGE_SWIPED` 每次 swipe 动画结束后单独发。位置见 `public/script.js:3740-3741`、3768-3771 与 10255。
- **interceptors**：生成拦截器按 manifest 顺序依次执行，任一拦截器调用 `abort(true)` 会立即终止后续拦截器，并让 `Generate` 短路返回。调度与短路点见 `public/scripts/extensions.js:2015-2040` 与 `public/script.js:4505-4511`。

## 6. 完成、异常、半截流与最终回写

- **流式完成**：流结束后，`onFinishStreaming` 先调用 `finalizeIntermediaryMessage` 做收尾（结算 swipes、把消息同步到当前 swipe 槽、保存 logprobs、发事件并按需解锁界面），再判定 auto_swipe，随后 `saveChatConditional()` 落盘并播放提示音。见 `public/script.js:3749-3759`。
- **非流式完成**：`onSuccess` 依次从响应中取出正文、清洗、交给 `saveReply` 落定（continue 类型走 appendFinal）、解析并保存 logprobs，然后处理工具调用分支，最后落盘。调用链在 `public/script.js:5402-5524`。
- **异常**：出错时 `onError` 弹出错误提示、解除生成锁、清空流式消费者再重新抛出；流式错误由 `onErrorStreaming` 中止请求，已生成的部分留在 `chat[]` 里，未发事件时也仍然可见。见 `public/script.js:5531-5541`。
- **半截流**：手动停止时 `stopGeneration` 让流式消费者收尾并中止网络请求，这次生成不保存；页面卸载时只中止请求。未停止的流要等 `onFinishStreaming` 才落盘。见 `public/script.js:5548-5559` 与 12401-12407。
- **工具调用收尾**：`finalizeIntermediaryMessage({unlockUI: false})` 先落定消息但保持输入框锁定，流式消费者要到工具结果处理完毕才置空，随后以 `depth + 1` 递归调用 `Generate('normal')` 继续本轮生成。流式结束与整个生成流程结束因此是两个时间点。见 `public/script.js:5357-5376`。

## 7. 停止、重试、续写与重新生成

| 机制 | 触发者 | 执行层语义 |
|---|---|---|
| 停止 | `stopGeneration()`（5548-5559）；`.mes_stop` 按钮（12070-12072）、Action Loader toast、Escape（12280-12287） | `streamingProcessor.onStopStreaming()`（保留下半截内存消息）+ `abortController.abort()`（网络中止，经服务端转发） |
| 重新生成 | 菜单 `option_regenerate`（11567-11580）、`/regenerate`（`slash-commands.js:1530`）、Ctrl+Enter | 单聊 `Generate('regenerate')`：`removeLastMessage` 删尾再生成；群聊 `regenerateGroup` 按 `gen_id` 删尾（`group-chats.js:167-188`） |
| 续写 | 菜单 `option_continue`（11586-11599）、`/continue`（`slash-commands.js:1489`）、Alt+Enter、auto_continue（`triggerAutoContinue` 5724-5733） | `Generate('continue')`：最后一条留在上下文里，`continue_mag` 记前缀，`saveReply` append |
| swipe 生成新候选 | swipe 越界 REGENERATE（10250-10260） | `Generate('swipe')`：`coreChat.pop()` 去掉最后一条（4438-4440）再生成，`saveReply` 的 swipe 分支写候选 |
| 手动重试 | 无 `/retry` 命令；错误后用户重新发送/重新生成 | 无自动重试（本次未找到后端重试逻辑） |

## 8. 队列、多会话并发与后台生成

- **同一会话串行**：生成由 `is_send_press` 这把模块级锁保证串行，发送按钮外面再包一层 `SimpleMutex`；swipe 与发送互斥，进入编辑态后发送和继续都被拒绝。判定见 `public/script.js:1707-1711` 与 11587-11590。
- **群聊内串行**：群聊生成由 `generateGroupWrapper` 循环驱动，用 `is_group_generating` 做重入保护；每轮按激活策略（NATURAL/LIST/POOLED/MANUAL，另对 swipe、continue、impersonate、quiet 有特例）选出成员，依次切换角色、发出草稿事件、调用 `Generate()`，必要时进入 auto-continue，全部成员完成后才解锁。批次标识取当前时间戳，即这批消息后续的 `extra.gen_id`。见 `public/scripts/group-chats.js:945-1092`。
- **后台生成**：生成期间输入框仍可用，那把锁只挡重复发送，但同一聊天的 swipe 与重新生成会被拒绝；群聊自动模式由核心代码内的 `setAutoModeWorker` 与 `groupChatAutoModeWorker` 两个定时 worker 驱动。见 `public/scripts/group-chats.js:144` 与 1398。
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

- **退出**：页面卸载时（`beforeunload`）中止正在进行的流式请求，已生成内容不写盘；流式中途的消息不持久化（见第 6 节），源码位置 `public/script.js:12401-12407`。
- **可观测性**：`power_user.console_log_prompts` 打印最终 prompt（5271-5273）；itemized prompts（每次生成的完整 prompt 与分项 token 数）写入 IndexedDB（5280-5322，见会话与消息管理笔记 2.1），供消息上的 Prompt 按钮查看；`GENERATION_STARTED/STOPPED/ENDED` 事件可供扩展记录。
- **已确认边界**：一次请求的上下文以 `finalPrompt`/`generate_data.prompt` 为准——设置面板或扩展 prompt 中配置的字段只在未被整体替换时进入本次请求（`GENERATE_AFTER_COMBINE_PROMPTS` 可整体替换）；文本 completion 与 OpenAI 两条拼装链在截断与注入顺序上实现完全不同；服务端只做代理，不持有会话状态。

## 11. 未验证事项

- OpenAI 路径的消息装填算法：只核实了预算入口与超限报错，`ChatCompletion` 与 `populateChatCompletion` 内部按消息、part 还是 system prompt 粒度裁剪，未逐行核对。
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
