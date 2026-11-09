# VCPChat 上下文编译与提示词工程调查笔记

> 调查对象：`https://github.com/lioensky/VCPChat`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`ce9882266782ffdd7b958bbf79d8db70480047c0`（分支：`main`）
>
> 调查方式：基于[对话请求与上下文笔记](../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md)及静态源码走读，核对单聊组装器、群聊上下文窗口和压缩模板的加载、消息编译与检查点提交；未运行真实模型请求
>
> 调查范围：已确认的请求上下文附加、上下文压缩检查点、群聊发言模式与上下文窗口、单聊统一组装器的消息与系统提示词编译；规则对象持久化、显示层规则和流式消费未在本次依据中确认
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPChat 的“上下文编译”证据现在集中在三层：单聊由统一组装器把历史、附件、正则、Tavern 规则、情绪提示、系统提示词和模型参数编成一次请求；群聊先由模式策略选择发言者，再为每个 agent 基于同一份内存群聊历史按窗口截取后构建上下文；主进程在发出前完成时间戳绑定、内部元数据剥离、可选参数省略和 VCP 扩展附加。`modules/chat/chatContextPipeline.js:319-417`、`modules/chat/singleChatRequestOrchestrator.js:7-40`、`Groupmodules/groupchat.js:931-1114`、`modules/ipc/chatHandlers.js:74-153`

上下文的选择规则不再只靠过滤 `isThinking`：单聊历史从最近的压缩检查点开始截取（`effectiveContextHistory`），群聊在启用窗口时只取最近 N 条消息发给模型，完整历史仍照常持久化。三模式提示词仍以 Agent 配置为权威，PromptSponsor 把模式、积木、轮换内容、仓库与预设管理暴露为受白名单约束的模型工具；它们与 Tavern 请求级注入是两套对象，不应混写为同一规则系统。`modules/chat/contextCompactionState.js:6-25`、`Groupmodules/groupContextWindow.js:11-39`、`modules/services/pluginAgentOperationService.js:26-49,377-640`

## 系统边界与规则编译主链

本专题只记录会改变请求层上下文或其上游选择结果的规则与编译动作。提交任务、Provider 调用、流式消费、取消、重试、并发和最终消息回写属于原笔记所覆盖的“对话请求与上下文”边界；消息 schema、持久化和恢复属于会话与消息管理；流式 DOM 更新属于消息渲染器。

群聊主链：

```text
群聊用户消息写入 groupHistory
  -> CHAT_MODES 选择 determineSpeakers 策略
  -> 直接提及、tag、@所有人、概率和保底条件判定
  -> 按用户最新消息中的 tag 命中情况排序发言者
  -> 每个 agent：selectGroupContextHistory 截窗口，基于当前内存 groupHistory 构建上下文
  -> 串行发起请求，前一个 agent 的回复写回后再构建下一个 agent 的上下文
```

单聊编译链（`chatContextPipeline.assembleRequestMessages`）：

```text
resolveConversationContext 解析会话配置与 Tavern 规则快照
  -> effectiveContextHistory 从最近压缩检查点起截取，并过滤 isThinking
  -> 逐条消息：附件/实时引用/媒体帧转换为 content parts，套用调用方文本变换
  -> 仅对当前 user 消息应用 Tavern user_suffix
  -> 合成 system prompt（会话前缀 + Agent systemPrompt + 情绪提示），应用 system_suffix
  -> 展开 {{VCPChatWorkSpace…}} 占位符，再把 context_inject 插入非 system 消息
  -> 构造模型参数并交给 send-to-vcp
  -> 主进程剥离内部元数据、省略未设置参数、附加 vcpchatExtensions.requestContext
```

群聊模式和单聊编译器不共享同一规则对象。群聊模式决定本轮有哪些 Agent 参与及其顺序；单聊组装器决定一个 Agent 请求里的消息和提示词。顺序模式现可保存自定义 speakerOrder，配置中不存在的旧成员被过滤，新成员按原成员顺序稳定追加。`Groupmodules/groupchat.js:35-40`、`:467-530`、`Groupmodules/modes/sequentialMode.js:20-36`

## 1. 规则对象、权威源与作用域

### 已确认的规则与输入

- 群聊模式由 `CHAT_MODES` 注册策略对象。当前注册 sequential、naturerandom、invite_only 与 game 四个入口，其中 game 只返回空发言者（游戏回合由游戏模块自行驱动）。其作用域是一次群聊消息处理及其中的 active members，证据为 `Groupmodules/groupchat.js:35-40,921-927`。
- 发言判定使用当前用户消息、最近历史和成员配置中的 tag 等输入。`naturerandom` 还区分用户/其他 agent 的提及与 agent 自己历史消息中的 tag。
- 群聊上下文窗口属于群组配置：`enableContextMessageWindow` 默认关闭，窗口大小默认 100、范围 1–10000，只影响发给模型的最近 N 条，不改持久化历史。证据为 `Groupmodules/groupContextWindow.js:11-39`、`Groupmodules/groupchat.js:974`。
- 单聊请求构建器附加 `vcpchatExtensions`：逐条消息生成 `messageId`、`role`、`timestamp`、`timestampIso`、`source: 'client_history'`、`sentMessageHash`（sha256）与 `sentMessageIndex`，并附加 `requestContext`（agentId/agentName/topicId/ownerType/isGroupMessage）。证据为 `modules/ipc/chatHandlers.js:74-120`。
- 未设置的可选模型参数在发出前被删除：`temperature`、`contextTokenLimit`、`max_tokens`、`top_p`、`top_k` 的 `null`、`undefined`、空串与非有限数都会被移除。证据为 `modules/ipc/chatHandlers.js:130-153`。

### 权威源与未确认部分

可持久化规则至少分四类：Agent 三模式提示词保存在 Agent 配置；Tavern 规则保存在独立规则库并带类型、作用域和启停状态，单聊从会话快照取规则、群聊在循环内注入；群聊模式设置位于群组配置的 `modeSettings`（含 sequential.speakerOrder 与 naturerandom.memberTags，旧字段作为迁移来源）；上下文压缩检查点作为带版本号的消息元数据保存在历史里。PromptSponsor 对提示词模式和积木操作采用命令白名单，并以 requestId 对写操作做十分钟进程内幂等；它没有独立规则版本字段，也未形成通用导入导出格式。`modules/services/pluginAgentOperationService.js:158-214,377-640`、`modules/chat/contextCompactionState.js:6-13`

因此，本笔记把上述内容称为“已确认的选择/请求变换”，不把它们进一步推断为完整的规则资产模型。

## 2. 选择条件、优先级与编译顺序

### 群聊选择规则

`sequential` 直接返回全部 active members，顺序取成员配置顺序。`invite_only` 直接返回空数组，自动发言不会由该模式产生，前端邀请入口另行触发。`game` 同样不自动选发言者，实际由游戏模块走自身回合流程。

`naturerandom` 的判定优先级已由原笔记确认，顺序为：

1. 当前消息中的直接 `@角色名`。
2. tag 匹配；strict 模式检查最近 8 条历史或当前用户消息，natural 模式按 tag 来源及最近发言情况使用确定性触发或动态概率。
3. `@所有人`。
4. 未触发成员的基础概率；strict 模式下历史 tag 命中可提升概率。
5. 所有条件都未命中时随机选择一名成员作为保底。

选出成员后，再按 tag 是否命中用户最新发言进行排序，命中者排在前面。这个排序决定后续 agent 的发言顺序，而不是已确认的 prompt 文本冲突解决器。证据集中在 `Groupmodules/modes/natureRandomMode.js:68-265`。

### 请求变换顺序

单聊组装器不执行 token 预算裁剪，只做两种历史截断：从最近压缩检查点起截取（检查点之前的历史不再发送），以及过滤 `isThinking` 临时消息。逐条消息先生成 content parts，再应用调用方提供的文本变换，随后仅对当前用户消息应用 user suffix，最后执行 post-process 钩子。系统提示词在消息循环之后合成，顺序是会话前缀、Agent systemPrompt（展开 `{{AgentName}}`）、情绪提示，再应用 Tavern system suffix，最后展开工作区占位符并将 context inject 插入非 system 消息。`modules/chat/chatContextPipeline.js:319-417`

附件路径也在此阶段成文：普通附件写成 `[附加文件: 路径 (类型)]…[/附加文件结束: 名称]` 文本块，扫描版 PDF 以多模态图像帧内联并标注页数，实时引用附件（笔记/工作区）每次构建时按源文件重新读取，失败则回退快照内容。工作区实时引用还会带上工作区别名与相对路径。`modules/chat/chatContextPipeline.js:86-135`、`:305-316`

群聊中，每个 agent 的上下文构建发生在发言者确定之后，并基于同一个内存 `groupHistory` 的当前状态；发送前按窗口配置截取最近 N 条。处理循环是串行的，所以前一个 agent 的新消息能够被后一个 agent 的上下文构建看到。证据为 `Groupmodules/groupchat.js:931-939`、`:972-975`、`:1105-1114`。

## 3. 请求层编译与模型可见结果

单聊请求层现由两层组成：渲染侧 `chatContextPipeline` 产出完整 `messages`（历史保留 role、name 与工具调用字段，附件形成文本说明和媒体 part，system 置于最前，三类 Tavern 规则在其中完成），主进程 `send-to-vcp` 再做去元数据、参数省略和扩展附加。实际 HTTP 入口是 `modules/ipc/chatHandlers.js:1056-1360`；旧的 `modules/vcpClient.js` 已在当前快照中删除，渲染进程的能力入口改为 `preloads/api/*`。

群聊请求层可确认的是：发言选择结果影响哪些 agent 依次获得上下文；每个 agent 的上下文由 `contextForAgentPromises` 构建，请求体经 `buildGroupRequestBody` 组装后发出。群聊 assistant 消息还保存 agent、模型和模型来源字段，但原笔记没有确认完整请求消息数组、system prompt 内容或这些字段如何映射到最终 Provider payload。`Groupmodules/groupchat.js:975-1114`、`:209-224`、`:1276`

本次没有证据证明显示预览中的文本必然等于最终模型输入，也没有证据证明 `requestContext` 会改写权威历史消息。上述请求层结果与完整 payload 属于不同证据层。

## 4. 消息生命周期变换与交接

已确认的交接点是：群聊 agent 发言选择和上下文构建发生在群聊主进程发起请求之前；同一次处理中的后续 agent 使用已经更新的内存 `groupHistory`，并在每个 agent 回复后写回历史。群聊主进程还作为历史单一真源负责消息落盘，渲染进程的 `saveHistoryForContext` 对群聊消息直接返回，避免重复保存造成竞态。相关事实见 `Groupmodules/groupchat.js:931-1114` 和原笔记第 6 节。

单聊压缩会向权威历史末尾追加 user 检查点，原始消息完整保留；发送选择器仅从最新有效检查点起取上下文，并无固定尾部保留窗口。检查点正文由可编辑的主模型接续模板合成，注入压缩报告及宿主保留的最新日记；元数据保存版本、审计结果和输入数量，发送前被剥离。依据：[历史选择](../../VCPChat/modules/chat/contextCompactionState.js#L6-L25)、[检查点正文与元数据](../../VCPChat/modules/chat/contextCompactionPrompts.js#L116-L152)。

压缩模型的系统模板、发送模板和接续模板分别从全局设置读取。发送模板里的 conversation_history 占位符展开为历史位置说明，真实历史以独立消息数组提供；原 system/developer 历史降为审计数据。上次快照遗漏的部分标识符会进入下一次审计回执，保真与连续性审计本身只记录警告，不构成拒绝落库的门槛。请求触发、超时、中止和提交快照校验见[对话请求与上下文笔记](../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md#33-上下文压缩检查点)。模板编译依据：[压缩模板与消息构建](../../VCPChat/modules/chat/contextCompactionPrompts.js#L55-L121)。

群聊发言规则影响请求参与者和上下文时机；压缩链则明确追加一条权威检查点消息，并在后续发送中改变上下文起点。普通消息的生成后改写与半截流最终化另见请求与会话管理类目。

## 5. 显示层投影与消息渲染器交接

Agent 正则仍有显示投影分支：渲染规则作用于完整消息文本和 DOM 结果，不改写历史真源；同一配置中的上下文规则则由请求编排调用方变换消息文本。二者共享规则资产但消费面不同，渲染实现见消息渲染器笔记。

因此，本次不能把群聊发言排序、请求上下文附加或 `finalizeStreamedMessage` 的文本选择描述为显示层规则。显示层是否存在独立规则对象、如何选择，以及其结果是否不进入请求和权威消息，均未在原笔记中确认。

## 6. 调试、预览与可解释性

实现路径集中在 `chatHandlers.js`，群聊模式的条件、概率和排序实现也在其中。这些属于静态源码可解释性，可核对对象是源码路径与实现条件；运行时调试面板与编译 trace 属于另一层能力，其覆盖情况见下段。

本次依据没有确认 VCPChat 能否查看命中规则、展开变量、显示编译后的 prompt、导出最终消息数组、生成差异或保存实时 trace。也没有确认任何预览是最终请求的权威快照。

## 7. 失败、更新与已确认边界

- 单聊编译顺序、附件 content parts、实时引用回读、三类 Tavern 注入、情绪提示与系统提示词展开已静态确认；服务端预算裁剪与最终 Provider 二次变换仍未确认。
- 群聊的 invite_only 模式以空发言者列表结束自动选择；naturerandom 有随机概率和最终保底；game 模式不出自动发言者。这些行为是代码路径事实，实际命中分布未运行验证。
- 工作区占位符展开失败、Tavern 规则不可用、情绪提示准备失败都会降级为原文或空串并继续发送，不阻断请求。`modules/chat/chatContextPipeline.js:253-271`、`:305-316`、`:436-447`
- 压缩检查点缺失或版本不符时按普通消息处理，不会把旧检查点当作有效截断点。`modules/chat/contextCompactionState.js:8-13`
- 原笔记没有确认变量缺失、脚本错误、循环替换、规则解析失败或规则版本更新的收口语义。
- 压缩检查点追加及其对后续上下文起点的影响已确认；其他规则是否在生成后改写权威历史仍未覆盖。

## 8. 未验证事项

- VCP 服务端收到请求后的预算裁剪、宏二次展开和 Provider payload 变换。
- `requestContext` 的完整 schema、来源、字段如何进入最终 Provider payload，以及是否会影响权威消息。
- 群聊成员配置、tag、概率、上下文窗口和模式是否可在界面编辑、持久化、导入导出或按会话/角色覆盖。
- 三种自动群聊模式的实际命中结果、随机分布，以及多条条件组合下的运行时顺序。
- 规则对象的版本、启停、互斥、冷却和冲突合成语义。
- 是否存在独立的显示层规则、命中预览、编译快照、差异或 trace。
- 规则解析错误、变量缺失、脚本异步行为、循环替换和更新迁移的错误收口。
- 重新生成与 FlowLock 是否在所有边界条件下完全复用单聊组装器；普通发送的附件进入请求体已确认。

## 9. 关键源码索引

- `modules/ipc/chatHandlers.js:74-153`：时间戳绑定与 sha256 摘要、requestContext 构造、内部元数据剥离、未设置可选参数省略。
- `modules/ipc/chatHandlers.js:1056-1360,1316-1327`：`send-to-vcp` 请求体组装与 `vcpchatExtensions` 附加。
- `modules/chat/chatContextPipeline.js:319-417`：单聊统一上下文组装入口与消息/系统提示词编译顺序。
- `modules/chat/chatContextPipeline.js:86-135,305-316,436-447`：附件与实时引用成文、工作区占位符展开、情绪提示解析。
- `modules/chat/singleChatRequestOrchestrator.js:7-40`：薄编排器，只负责 buildRequest/sendPrepared/send。
- `modules/chat/contextCompactionState.js:6-25`：压缩检查点判定与发送侧历史截取。
- `modules/services/pluginAgentOperationService.js:26-49,377-640`：PromptSponsor 命令白名单、幂等写入与三模式提示词资产操作。
- `Groupmodules/groupchat.js:35-40,921-1114`：群聊模式注册、模式选择、串行处理与逐 agent 上下文化。
- `Groupmodules/groupContextWindow.js:11-39`：群聊上下文窗口配置与最近 N 条截取。
- `Groupmodules/modes/sequentialMode.js`：全部成员按配置顺序发言。
- `Groupmodules/modes/natureRandomMode.js:68-265`：直接提及、tag、概率、`@所有人`、保底和最终排序。
- `Groupmodules/modes/inviteOnlyMode.js`、`Groupmodules/modes/jevDecisionMode.js`：不自动选择发言者的模式与 Jev 群聊决策配置。
- `preloads/api/chat.js`：渲染进程聊天能力入口（旧 `modules/vcpClient.js` 已删除）。
- `renderer.js:562-859`、`modules/renderer/streamManager.js:1731-1946`：流事件分发和最终化交接；显示渲染与消息回写不属于本专题的规则证据。
