# VCPToolBox 上下文编译与提示词工程调查笔记

> 调查对象：`https://github.com/lioensky/VCPToolBox`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`e2762e4dab5c70952d88f96689fba1270624e5ef`（分支：`main`）
>
> 调查方式：基于既有对话请求与上下文调查笔记，复用其已确认的源码阅读结果；涉及 `modules/chatCompletionHandler.js`、`messageProcessor.js`、`roleDivider.js`、`Plugin.js` 及 VCPTavern、RAGDiaryPlugin、VCPTimeLine、ContextFoldingV2、OneRing 的消息处理路径
>
> 调查范围：单次聊天请求中预设、占位符与消息预处理器的选择、展开、排序及其请求层、消息层和客户端显示层去向；不覆盖规则编辑器、持久化 schema、导入导出和运行时交互验证
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPToolBox 的上下文编译发生在单次 HTTP 请求内。客户端提交的消息先经过上下文裁剪、VCPTavern 预设注入、权限受限的占位符展开和按序插件预处理，随后经检测器与角色拆分，才成为首次上游请求的 messages；处理后的数组也会写回本次请求体（`modules/chatCompletionHandler.js:809-1148`）。

- 已确认的规则对象包括 VCPTavern 预设触发器、系统消息中的 Agent/Toolbox 与其他动态占位符、以及插件注册的 messagePreprocessors；原笔记未确认它们的通用持久化 schema、版本、启停字段或导入导出语义。
- 选择边界并不统一：VCPTavern 触发器只从 system 消息发现；Agent/Toolbox 只可由 system 或特定系统前缀 user 消息展开；RAG、时间线和折叠器也各自限定可信载体与触发器。不能将任意消息中的同名文本视为可执行规则。
- 已确认的初始请求顺序是：裁剪与若干顶层标记消费，VCPTavern 注入，逐条变量解析，多模态和其他插件预处理，检测器及 Role Divider，最后构造上游 body。插件排序由保存的优先顺序加上未列项的名称排序决定。
- 请求层、模型循环消息层与客户端显示层并非同一份内容。预处理后的数组进入首次上游请求；工具循环维护独立消息数组；推理字段包装和 VCP 工具信息仅改变客户端 SSE/JSON 或响应内容，不会成为模型下一轮上下文。
- 可解释表面以首次 fetch 前的内存快照和可选 ChatLog 为主。前者只覆盖首次请求，后者默认关闭；原笔记未确认规则命中列表、变量展开差异或编辑器预览是否存在。

## 系统边界与规则编译主链

本专题将可编辑或配置驱动、且会改变消息数组、上游输入或客户端消息投影的预设、占位符和预处理器视为规则编译对象。普通客户端历史提交、上游调用、工具执行和会话持久化留在相邻专题：VCPToolBox 不拥有跨请求会话消息存储，外部客户端需自行保存并重新提交历史。

```text
客户端 messages
  -> 字符数裁剪与顶层标记消费
  -> VCPTavern 预设注入
  -> 逐条变量、Agent/Toolbox 及动态占位符展开
  -> 多模态处理器与已排序的插件 messagePreprocessors
  -> Detector/SuperDetector 与 Role Divider
  -> processedMessages 写入 originalBody.messages
  -> 首次上游请求和 finalContextStore 快照
  -> 如触发 VCP 工具循环：独立循环 messages 追加 assistant 正文和工具 payload
  -> SSE/JSON 的推理包装与 VCP 信息投影
```

该主链的已确认入口是 `ChatCompletionHandler.handle()`；最终首次请求使用处理后的 `originalBody.messages` 构造，工具递归则以独立循环数组重新请求（`modules/chatCompletionHandler.js:644-1148`；`modules/handlers/streamHandler.js:429-709`）。

## 1. 规则对象、权威源与作用域

VCPTavern 通过 system 消息中的 `{{VCPTavern::Preset...}}` 触发预设。触发器仅从 system 消息查找，处理时会删除触发器本身及其他消息里残留的同名触发器；预设可按 embed、relative、depth 三种方式把文本或新消息对象并入数组（`Plugin/VCPTavern/VCPTavern.js:239-250,291-310,419-580`）。原笔记确认预设声明可限制允许展开的运行时占位符，且仅标为伪系统消息的文本可以展开；嵌套消息对象会递归处理（`Plugin/VCPTavern/VCPTavern.js:155-242,397-640`）。

通用变量处理按单条消息进行。Agent 与 Toolbox 只允许在 system，或以 `[系统提示:]`、`[系统邀请指令:]` 开头的 user 消息中展开；一次请求至多展开一个 Agent，重名 Toolbox 至多展开一次。时间、环境、SAR、日记/知识库、动态工具及插件描述等属于同一后续占位符处理阶段（`modules/messageProcessor.js:153-248,601-871`）。

原笔记还确认三种以系统或可信系统载体为边界的插件规则：RAGDiaryPlugin 处理 system 或系统前缀 user 中的日记本/知识库占位符；VCPTimeLine 只采用首个可信载体中的一次时间线声明；ContextFoldingV2 需要 system 中的激活占位符。这些规则直接改写本次消息数组，而不是维护独立会话历史（相关实现见 `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1135-1419`、`Plugin/VCPTimeLine/VCPTimeLine.js:372-416`、`Plugin/ContextFoldingV2/ContextFoldingV2.js:164-290`）。

规则对象的保存位置、schema、版本字段、启停状态以及导入导出语义，原笔记没有已确认事实。本次也不把占位符出现在消息文本中等同于其已命中或已展开。

## 2. 选择条件、优先级与编译顺序

初始请求的固定阶段顺序如下：

1. 若提交 `contextTokenLimit`，先按字符数估算裁剪消息；system、系统提示前缀 user 与最后两条消息受到保留规则保护。
2. 消费连续顶层 system 中的 `[[VCPToolUse=Forbidden]]`，并识别 TransBase64 标记以决定后续多模态处理。
3. 执行 VCPTavern 注入；若请求使用语义路由模型，再从注入后的消息选择真实后端模型并应用相关设置。
4. 深拷贝各消息，执行变量及可授权对象展开。
5. 先调用配置选定的多模态处理器，再执行其余插件预处理器。
6. 清理或还原 TransBase64+，运行 Detector/SuperDetector，最后按开关运行 Role Divider。

该顺序来自 `modules/chatCompletionHandler.js:809-1124`。因此，预设插入的内容能参与之后的变量解析和插件处理；裁剪发生在预设注入之前。裁剪是字符数估算，不是摘要压缩，也不保证严格 token 上限（`modules/contextManager.js:10-95`）。

多个插件的先后由 `preprocessor_order.json` 的已知顺序优先，未列插件再按名称排序追加。当前保存的已知顺序为 VCPTavern、ImageProcessor、RAGDiaryPlugin、VCPTimeLine、OpenHerPersona、OneRing、ContextFoldingV2；这一规则由 `Plugin.js:881-904` 应用。原笔记仅能确认未列插件的静态排序规则，不能确认各安装环境实际注册的完整集合。

各插件自己的命中条件进一步限制其效果。RAGDiaryPlugin 无占位符时会提前返回；VCPTimeLine 仅接受一次声明并清空其他同名占位符；ContextFoldingV2 按 assistant 历史块深度、向量相似度、已有摘要和阈值决定是否用摘要替换内容。OneRing 则把触发器改成系统通知，并可追加上下文或时间标记、在数组附加元数据（`Plugin/OneRing/OneRing.js:929-950`）。

## 3. 请求层编译与模型可见结果

Role Divider 是请求层最后的已确认结构化变换之一：它可识别角色分隔标签并拆出新消息，同时保护工具请求和 DailyNote 标记块不被拆开。处理结束后，`processedMessages` 赋回 `originalBody.messages`，首次上游 body 从该对象复制构造，因而此时的预设注入、占位符替换、检索文本、折叠结果和角色拆分都属于模型可见输入（`modules/roleDivider.js:11-27,101-121,383-399`；`modules/chatCompletionHandler.js:1098-1148`）。

RAGDiaryPlugin 的查询内容来自最近真实 user 与最近 assistant 的加权内容，命中后将结果替换进占位符所在消息，必要时还收集多模态附件。ContextFoldingV2 则对符合条件、已有摘要的 assistant 历史内容原地替换；未完成摘要时会异步触发。两者都说明规则结果进入本次数组，但原笔记未提供真实请求快照来确认不同插件组合下的实际展开结果。

首次 fetch 前，处理后的请求会写入 `finalContextStore`，最多保留五组并附带 token 统计摘要。这是调试快照，而非会话事实源，也不包含之后的 VCP 工具递归回合（`modules/finalContextStore.js:10-19,40-133,288-301`）。

## 4. 消息生命周期变换与交接

初始编译的结果只在本次请求内写回请求 body，不会由服务端持久化为会话消息。首次模型响应后，流式与非流式处理器都创建独立的循环上下文：将 assistant 正文追加到该数组，执行 VCP 工具后再追加带 `<!-- VCP_TOOL_PAYLOAD -->` 的 user 工具结果，并以这份数组再次 POST。此后模型读取的是循环数组，不是客户端的原始会话或首次快照（`modules/handlers/streamHandler.js:68,429-439,580-688`；`modules/handlers/nonStreamHandler.js:306,422-444,507-518`）。

工具循环内的 assistant 正文可再次经过启用的 Role Divider 分支。`RAGMemoRefresh` 开启时，追加工具 payload 前还会刷新历史中的 RAG 块，但查询使用最近真实 user，明确跳过工具 payload 和系统前缀 user。该机制是递归请求前的消息更新，不构成跨请求写回（`modules/chatCompletionHandler.js:531-625`）。

原笔记确认流式与非流式完成时都只构造响应内容；非流式会把面向客户端的会话文本写到内存响应 body。结合已读聊天入口，本次未找到服务端把规则编译结果、模型输出或工具循环消息写入会话存储的路径。

## 5. 显示层投影与消息渲染器交接

推理字段与模型正文分流。工具循环和 OneRing 只读取模型 `message.content`；推理字段单独保存，不会混入工具解析或后续模型上下文。只有当模型匹配推理转正文配置时，响应适配器才在发给客户端的 SSE/JSON 中将推理内容包为 `<think>` 或 `<thinking>`；内部循环仍使用原始正文（`modules/reasoningContentAdapter.js:41-49,128-138`；`modules/handlers/streamHandler.js:158-218`）。

VCP 工具结果汇总、成功或失败摘要同样只写入客户端输出。模型下一轮接收的是独立的 `VCP_TOOL_PAYLOAD`，而不是 `vcpInfoHandler.streamVcpInfo()` 生成的显示文本；关闭 `SHOW_VCP_OUTPUT` 时，`mark_history` 仍可强制显示单次调用（`modules/vcpInfoHandler.js:96-153`；`modules/handlers/streamHandler.js:594-663`）。

因此，推理包装与 VCP 信息属于已确认的显示层投影，不应据此推断它们改写了权威请求消息或模型递归历史。原笔记未覆盖客户端 Markdown、DOM 渲染或这些投影在具体前端的展示实现。

## 6. 调试、预览与可解释性

`finalContextStore` 提供首次上游请求前的有限内存快照及 token 统计，最多五组；它能用于查看初始编译后的请求，但不能代表工具递归中的后续消息。启用 `CHAT_LOG_ENABLED` 后，ChatLog 会异步写入初始请求以及每轮 request、toolCalls、response；该日志默认关闭，也不构成会话持久化（`server.js:371,478-499`；流式记录点见 `modules/handlers/streamHandler.js:413-738`）。

原笔记没有确认可展示规则命中、变量逐项展开、预设差异、编辑器预览或完整最终递归消息数组的专门调试界面。上述快照和日志是否在运行时完整反映异步插件及所有组合，仍需运行验证。

## 7. 失败、更新与已确认边界

本次已确认的编译收口主要是按条件跳过或清理：RAGDiaryPlugin 在无占位符时早退，VCPTimeLine 清空多余同名占位符，ContextFoldingV2 从最终 system 文本移除激活开关；Role Divider 保护工具和 DailyNote 块以避免拆分。VCPTavern 的残留触发器也会被删除。这些是具体处理路径，不能推出所有规则解析、变量缺失、脚本异常或循环替换都有统一错误模型。

关于规则更新，本次唯一已确认事实是多模态纯文本 tag 列表来自热加载的 `multiModalConfigStore`，它会影响自动强制翻译判定（`modules/chatCompletionHandler.js:676-687,949-970`）。预设、插件配置和其他规则对象更新后何时生效，以及版本迁移和导入导出行为，原笔记未覆盖。

## 8. 未验证事项

- 未运行真实上游模型，未取得各插件组合、VCPTavern 作用点和嵌套消息展开后的最终 messages 快照。
- 未验证实际预设命中、允许名单、深度与 relative 插入相互作用，以及异步折叠结果何时进入请求。
- 未确认规则对象的存储位置、schema、版本、启停状态、导入导出和编辑器交互。
- 未确认安装环境中未列入 `preprocessor_order.json` 的插件集合及其实际完整排序。
- 未运行验证推理包装、工具信息投影、ChatLog 与 `finalContextStore` 在流式、中断和上游错误情形下的可见内容。

## 9. 关键源码索引

- `modules/chatCompletionHandler.js:644-1148`：初始请求的裁剪、预设、变量、预处理器、检测与最终请求构造主链。
- `modules/messageProcessor.js:153-248,575-599,601-871`：Agent/Toolbox 权限边界、检测器和其他占位符展开。
- `Plugin/VCPTavern/VCPTavern.js:155-242,239-250,291-310,314-640`：预设触发、时间变量、允许展开边界和注入方式。
- `Plugin.js:881-904` 与 `preprocessor_order.json`：预处理器排序。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1135-1419`、`Plugin/VCPTimeLine/VCPTimeLine.js:372-416`、`Plugin/ContextFoldingV2/ContextFoldingV2.js:164-290`、`Plugin/OneRing/OneRing.js:929-950`：插件选择条件及消息数组变换。
- `modules/roleDivider.js:11-27,101-121,383-399`：角色拆分及受保护文本块。
- `modules/handlers/streamHandler.js`、`modules/handlers/nonStreamHandler.js`：工具递归消息与客户端输出的分流。
- `modules/reasoningContentAdapter.js`、`modules/vcpInfoHandler.js`：推理和工具信息的显示层投影。
- `modules/finalContextStore.js`、`server.js:371,478-499`：首次请求快照与可选 ChatLog。
