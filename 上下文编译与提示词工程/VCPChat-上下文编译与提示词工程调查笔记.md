# VCPChat 上下文编译与提示词工程调查笔记

> 调查对象：`https://github.com/lioensky/VCPChat`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`429a96829da0149ff59b6758748795a2934bdc9d`（分支：`main`）
>
> 调查方式：仅依据 [`../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md`](../对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md) 已确认的静态源码证据整理；不补查原笔记未展开的规则编译路径
>
> 调查范围：已确认的请求上下文附加、可选模型参数清理、群聊发言模式选择及其进入 agent 上下文的交接；规则对象持久化、单聊上下文编译、最终请求消息数组、消息改写和显示层规则未在本次依据中确认
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPChat 当前可由原笔记确认的“上下文编译”证据，集中在两条路径：单聊发送前由 `chatHandlers.js` 构造请求上下文并清理未设置的采样参数；群聊先由模式策略选择发言者，再为每个 agent 基于内存中的群聊历史构建上下文。前者确认了请求构建阶段存在附加和规范化，后者确认了规则选择与 agent 请求之间的交接。

单聊现由独立的请求编排器集中完成历史筛选、附件转换、消息正则、Tavern 规则、系统提示词和模型参数组装，因此这些阶段的先后关系已可静态确认。三模式提示词仍以 Agent 配置为权威，PromptSponsor 还把模式、积木、轮换内容、仓库与预设管理暴露为受白名单约束的模型工具；它们与 Tavern 请求级注入是两套对象，不应混写为同一规则系统。`modules/chat/singleChatRequestOrchestrator.js:254-353`、`modules/services/pluginAgentOperationService.js:5-28,323-586`

## 系统边界与规则编译主链

本专题只记录会改变请求层上下文或其上游选择结果的规则与编译动作。提交任务、Provider 调用、流式消费、取消、重试、并发和最终消息回写属于原笔记所覆盖的“对话请求与上下文”边界；消息 schema、持久化和恢复属于会话与消息管理；流式 DOM 更新属于消息渲染器。

依据原笔记能够确认的主链如下：

```text
群聊用户消息与当前 groupHistory
  -> CHAT_MODES 选择 determineSpeakers 策略
  -> 直接提及、tag、@所有人、概率和保底条件判定
  -> 按用户最新消息中的 tag 命中情况排序发言者
  -> 为每个 agent 基于当前内存 groupHistory 构建上下文
  -> agent 依次发起请求
```

单聊编译链为：

```text
过滤 isThinking 历史
  -> 附件路径、提取文本和媒体帧转换为 content parts
  -> 按消息轮次应用上下文正则
  -> 仅对当前 user 消息应用 Tavern user_suffix
  -> 展开 Agent 名称并合成 system prompt
  -> 应用 Tavern system_suffix，再把 context_inject 插入非 system 消息
  -> 构造模型参数并交给 send-to-vcp
  -> 主进程执行思维链剥离、context sanitizer、参数省略与 requestContext 附加
```

群聊模式和单聊编译器不共享同一规则对象。群聊模式决定本轮有哪些 Agent 参与及其顺序；单聊编译器决定一个 Agent 请求里的消息和提示词。顺序模式现可保存自定义 speakerOrder，配置中不存在的旧成员被过滤，新成员按原成员顺序稳定追加。`Groupmodules/groupchat.js:266-309`、`Groupmodules/modes/sequentialMode.js:20-36`

## 1. 规则对象、权威源与作用域

### 已确认的规则与输入

- 群聊模式由 `CHAT_MODES` 注册策略对象。已确认的模式包括 sequential、naturerandom 和 invite_only；各模式通过 `determineSpeakers` 返回本轮发言者。其作用域是一次群聊消息处理及其中的 active members，证据为 `Groupmodules/groupchat.js:22-26` 及三个模式文件。
- 发言判定使用当前用户消息、最近历史和成员配置中的 tag 等输入。`naturerandom` 还区分用户/其他 agent 的提及与 agent 自己历史消息中的 tag。
- 单聊请求构建器附加 `vcpchatExtensions.requestContext`，并对未设置的可选模型参数进行清理。这些是请求构建阶段已确认的输入变换，证据为 `modules/ipc/chatHandlers.js:53-118`、`:1064`、`:1071`。

### 权威源与未确认部分

可持久化规则至少分三类：Agent 三模式提示词保存在 Agent 配置；Tavern 规则保存在独立规则库并带类型、作用域和启停状态；群聊模式设置位于群组配置的 `modeSettings`。PromptSponsor 对提示词模式和积木操作采用命令白名单，并以 requestId 对写操作做十分钟进程内幂等；它没有独立规则版本字段，也未形成通用导入导出格式。`modules/services/pluginAgentOperationService.js:134-190,323-586`

因此，本笔记把上述内容称为“已确认的选择/请求变换”，不把它们进一步推断为完整的规则资产模型。

## 2. 选择条件、优先级与编译顺序

### 群聊选择规则

`sequential` 直接返回全部 active members，顺序取成员配置顺序。`invite_only` 直接返回空数组，自动发言不会由该模式产生，前端邀请入口另行触发。

`naturerandom` 的判定优先级已由原笔记确认，顺序为：

1. 当前消息中的直接 `@角色名`。
2. tag 匹配；strict 模式检查最近 8 条历史或当前用户消息，natural 模式按 tag 来源及最近发言情况使用确定性触发或动态概率。
3. `@所有人`。
4. 未触发成员的基础概率；strict 模式下历史 tag 命中可提升概率。
5. 所有条件都未命中时随机选择一名成员作为保底。

选出成员后，再按 tag 是否命中用户最新发言进行排序，命中者排在前面。这个排序决定后续 agent 的发言顺序，而不是已确认的 prompt 文本冲突解决器。证据集中在 `Groupmodules/modes/natureRandomMode.js:68-265`。

### 请求变换顺序

单聊历史只过滤 `isThinking` 临时消息，没有在编排器内执行 token 截断。每条消息先生成 content parts，再应用调用方提供的文本变换；当前用户消息随后应用 user suffix。系统提示词在消息循环之后展开 Agent 名称并合成前缀、主体和追加段，再应用 system suffix；context inject 最后插入非 system 消息。预算裁剪若由 VCP 服务端执行，仍不属于当前客户端可确认范围。`modules/chat/singleChatRequestOrchestrator.js:288-353`

群聊中，每个 agent 的上下文构建发生在发言者确定之后，并基于同一个内存 `groupHistory` 的当前状态。处理循环是串行的，所以前一个 agent 的新消息能够被后一个 agent 的上下文构建看到。证据为 `Groupmodules/groupchat.js:585-591`、`:611-719` 以及其 `for...of await` 调度（`:578-579`）。

## 3. 请求层编译与模型可见结果

单聊请求层现在可以确认到完整 `messages` 的紧邻构建器：历史消息保留 role、name 与工具调用字段，附件可形成文本说明和 `image_url` part，system 消息置于最前，三类 Tavern 规则在 renderer 编排器内完成。主进程随后执行协议清理和 VCP 扩展附加；实际 HTTP 入口仍是 `modules/ipc/chatHandlers.js:983-1409`，不是未接线的 `modules/vcpClient.js`。

群聊请求层可确认的是：发言选择结果影响哪些 agent 依次获得上下文；每个 agent 的上下文由 `contextForAgentPromises` 构建。群聊 assistant 消息还保存 agent、模型和模型来源字段，但原笔记没有确认完整请求消息数组、system prompt 内容或这些字段如何映射到最终 Provider payload。

本次没有证据证明显示预览中的文本必然等于最终模型输入，也没有证据证明 `requestContext` 会改写权威历史消息。上述请求层结果与完整 payload 属于不同证据层。

## 4. 消息生命周期变换与交接

已确认的交接点是：群聊 agent 发言选择和上下文构建发生在群聊主进程发起请求之前；同一次处理中的后续 agent 使用已经更新的内存 `groupHistory`。群聊主进程还作为历史单一真源负责消息落盘，渲染进程的 `saveHistoryForContext` 对群聊消息直接返回，避免重复保存造成竞态。相关事实见 `Groupmodules/groupchat.js:611-719` 和原笔记第 6 节。

这些证据说明规则选择结果会影响后续请求的参与者和上下文时机，但没有确认规则会在生成前后改写权威消息、生成结果或后续历史字段。半截流最终化、写回和恢复语义留在原笔记及会话与消息管理类目，不在这里重复展开。

## 5. 显示层投影与消息渲染器交接

Agent 正则仍有显示投影分支：渲染规则作用于完整消息文本和 DOM 结果，不改写历史真源；同一配置中的上下文规则则由请求编排调用方变换消息文本。二者共享规则资产但消费面不同，渲染实现见消息渲染器笔记。

因此，本次不能把群聊发言排序、请求上下文附加或 `finalizeStreamedMessage` 的文本选择描述为显示层规则。显示层是否存在独立规则对象、如何选择，以及其结果是否不进入请求和权威消息，均未在原笔记中确认。

## 6. 调试、预览与可解释性

原笔记提供了可定位源码和实际路径差异：它确认真正使用的是 `chatHandlers.js`，并以未引用的 `vcpClient.js` 作对照；也记录了群聊模式的条件、概率和排序实现。这些属于静态源码可解释性，不等同于运行时调试面板或编译 trace。

本次依据没有确认 VCPChat 能否查看命中规则、展开变量、显示编译后的 prompt、导出最终消息数组、生成差异或保存实时 trace。也没有确认任何预览是最终请求的权威快照。

## 7. 失败、更新与已确认边界

- 单聊编译顺序、附件 content parts、三类 Tavern 注入和系统提示词展开已静态确认；服务端预算裁剪与最终 Provider 二次变换仍未确认。
- 群聊的 invite_only 模式以空发言者列表结束自动选择；naturerandom 有随机概率和最终保底；这些行为是代码路径事实，实际命中分布未运行验证。
- 单聊请求没有被原笔记确认存在客户端超时或本地 AbortController；这属于请求运行时可靠性边界，不应误写成规则编译失败处理。
- 原笔记没有确认变量缺失、脚本错误、循环替换、规则解析失败或规则版本更新的收口语义。
- 规则是否写回消息、是否影响后续历史，以及显示层规则是否与请求层共享配置，均没有足够证据确认。

## 8. 未验证事项

- VCP 服务端收到请求后的预算裁剪、宏二次展开和 Provider payload 变换。
- `requestContext` 的完整 schema、来源、字段如何进入最终 Provider payload，以及是否会影响权威消息。
- 群聊成员配置、tag、概率和模式是否可在界面编辑、持久化、导入导出或按会话/角色覆盖。
- 三种群聊模式的实际命中结果、随机分布，以及多条条件组合下的运行时顺序。
- 规则对象的版本、启停、互斥、冷却和冲突合成语义。
- 是否存在独立的显示层规则、命中预览、编译快照、差异或 trace。
- 规则解析错误、变量缺失、脚本异步行为、循环替换和更新迁移的错误收口。
- 重新生成与 FlowLock 是否在所有边界条件下完全复用单聊编排器；普通发送的附件进入请求体已确认。

## 9. 关键源码索引

- `modules/ipc/chatHandlers.js:53-118,855-1270`：请求上下文附加、未设置可选模型参数清理及实际 `send-to-vcp` 请求路径。
- `modules/chat/singleChatRequestOrchestrator.js:254-353`：单聊历史、附件、正则、Tavern 规则、系统提示词和模型参数编译顺序。
- `modules/services/pluginAgentOperationService.js:5-28,323-586`：PromptSponsor 命令白名单、幂等写入与三模式提示词资产操作。
- `Groupmodules/groupchat.js:22-26,477-719`：群聊模式注册、群聊上下文构建和内存 `groupHistory` 交接。
- `Groupmodules/groupchat.js:578-591`：群聊 agent 处理的串行顺序及使用内存历史的设计取舍。
- `Groupmodules/modes/sequentialMode.js`：全部成员按配置顺序发言。
- `Groupmodules/modes/natureRandomMode.js:68-265`：直接提及、tag、概率、`@所有人`、保底和最终排序。
- `Groupmodules/modes/inviteOnlyMode.js`：不自动选择发言者的模式。
- `modules/vcpClient.js:1-589`：未被引用的另一套请求实现，仅作为静态对照，不能代表实际运行链。
- `renderer.js:540-764`、`modules/renderer/streamManager.js:2190-2400`：流事件分发和最终化交接；显示渲染与消息回写不属于本专题的规则证据。
