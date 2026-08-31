# Risuai 上下文编译与提示词工程调查笔记

> 调查对象：`https://github.com/kwaroran/Risuai`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`e565563a288ebe4c65b6099a1645ba477d1c84b4`（分支：`main`）
>
> 调查方式：基于既有《Risuai 对话请求与上下文调查笔记》的静态源码追踪结论，重组其中已确认的 `sendChat`、lorebook、触发脚本、请求构建与流式写回链路；未运行应用
>
> 调查范围：可编辑提示词模板、旧式分组顺序、lorebook、触发脚本、Lua 与正则脚本在上下文构建、请求改写和输出处理中的已确认交接；不重新调查会话 schema、规则编辑器、导入导出、消息渲染实现、Provider 协议和工具执行细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

- Risuai 的请求上下文由 `sendChat` 编译：它先建立各来源的分组桶，再以提示词模板卡片的顺序，或无模板时的旧式 `formatingOrder`，生成最终消息数组。模板中的 persona、描述、作者注和记忆卡可指定 user、assistant 或 system；未指定时为 system。最终数组交给 `requestChatData`，而非编辑器预览，是模型可见结果的依据（`src/ts/process/index.svelte.ts:410-611, 1271-1497`）。
- lorebook 是位置和深度都参与编译的规则来源。激活条目可进入普通 lorebook 桶、围绕角色描述的位置、收尾桶或历史深度；正文中的 `@@role` 优先于条目的默认角色，位置引用可递归解析至五层（`src/ts/process/index.svelte.ts:498-611, 1056-1066`）。原笔记确认其扫描角色、聊天和模块三层词条，但未涵盖词条的持久化 schema、编辑和导入导出语义。
- 触发脚本与 Lua 钩子处在不同阶段：`start` 可追加提示或停止发送，`request` 在每次模型尝试前改写已拼装数组，`output` 在流结束后运行；Lua `editRequest` 位于最终拼装后、请求前。正则脚本另有 editinput、editprocess、editoutput、editdisplay 四种模式，但本次已有证据只追到前三者的调用，不能由配置名推断 editdisplay 的实际显示效果。
- 输出处理不会直接证明请求被改写。流式块在消费端经 editoutput 后整体写回占位消息；`output` 触发脚本、inlay、插件监听与 TTS 在流结束后依次执行。它们属于生成后消息生命周期或后续副链，而非本轮输入的请求层编译（`src/ts/process/index.svelte.ts:1591-1793`）。
- 可解释性表面包括 DevTool/快捷键的 preview 模式，可核对 `requestChatData` 实际收到的消息数组；fetch 日志以 chatId 关联请求，且源码存在输出完整 prompt 与记忆数据的 `console.log`。预览是否覆盖每一种规则组合及其与最终网络 payload 的一致性，尚未运行验证。

## 系统边界与规则编译主链

本专题将提示词模板、旧式分组顺序、lorebook、触发脚本、Lua 钩子和正则脚本视为规则对象或规则处理器，记录它们何时改变请求数组、生成消息或显示投影。会话和消息的 schema、保存与恢复留在会话与消息管理；提交、重试、Provider 调用和流式协议留在对话请求与上下文；DOM 渲染留在消息渲染器。

```text
sendChat()
  -> 读取模板卡片或旧式分组顺序，并为各提示来源预检 token
  -> 角色字段、lorebook、persona、作者注、历史及记忆分别进入分组桶
  -> 历史逐条 editprocess；depth lorebook 插入历史；记忆阶段处理
  -> start 触发脚本按位置插入附加提示
  -> 按模板卡片或旧式顺序拼装最终消息数组
  -> 角色 depth_prompt -> Lua editRequest
  -> requestChatData()：每次尝试执行 request 触发脚本后交给 Provider
  -> 流式累计文本 -> editoutput -> 写回占位消息
  -> output 触发脚本、inlay、插件监听与 TTS
```

上述顺序来自 `src/ts/process/index.svelte.ts:676-829, 888-898, 900-1053, 1197-1216, 1271-1523` 与 `src/ts/process/request/request.ts:247-272`。token 预算会在拼装前预检、记忆阶段处理后及最终数组形成后再次影响可保留内容；其截断和摘要策略属于对话请求与上下文主题，本笔记仅将其作为规则编译的前后约束。

## 1. 规则对象、权威源与作用域

提示词模板卡片是请求数组排序的主要规则对象；未使用模板时，旧式 `formatingOrder` 提供分组顺序。已确认卡片类型依序包含 persona、description、authornote、lorebook、postEverything、plain/jailbreak/cot、chatML、chat、memory 与 cache。`chat` 卡还可用范围字段选择历史区间，并可把整段转成 system。原笔记没有记录模板卡片的保存位置、版本、启停字段或导入导出语义。

lorebook 的激活结果由 `loadLoreBookV3Prompt` 提供给 `sendChat`。原笔记确认扫描范围覆盖角色、聊天和模块三层，并受扫描深度、正则或全词匹配和 lorebook token 预算约束；激活结果再按位置进入不同桶。条目如何绑定这些来源、冲突时的完整排序，以及词条自身的持久化与导入导出，本次未确认（`src/ts/process/lorebook.svelte.ts:75-`；`src/ts/process/index.svelte.ts:498-611`）。

触发脚本、Lua 编辑钩子和正则脚本也是可改变文本的规则来源。原笔记确认触发脚本有 start、request、output 三个时机，Lua 有 editRequest 处理，正则脚本声明 editinput、editoutput、editprocess、editdisplay 四模式；各对象的 schema、启停状态、作用域选择和导入导出未在原笔记中调查。

## 2. 选择条件、优先级与编译顺序

规则首先受聊天形态和开关约束。非群聊且未重置时加入开场白；persona prompt、jailbreak、链式思考指令、聊天或默认作者注等分别由对应配置控制。群聊会追加“只扮演当前角色”的指令，且历史消息可由群聊模板重包并按 `groupOtherBotRole` 改变角色。这些是已确认会改变入桶内容的条件（`src/ts/process/index.svelte.ts:410-496, 831-884, 900-1053`）。

lorebook 的位置决定去向：未指定位置的条目进入 lorebook 桶；before/after description 以及 personality/scenario 位置围绕角色描述；深度为 0 的条目进入 postEverything；深度大于 0 或 reverse_depth 的条目在历史阶段按深度插入。assistant 角色条目延后处理；条目正文 `@@role` 覆盖其默认角色。`{{position::}}` 引用在注入时递归展开，最大嵌套为五层（`src/ts/process/index.svelte.ts:498-611, 1056-1066`）。

历史在规则处理前从后向前选择：`disabled === true` 的消息跳过，遇到 `disabled === 'allBefore'` 则清空此前消息。随后每条保留历史执行 editprocess，原笔记将其确认为正则、Lua `editInput` 与宏的组合处理。原笔记未列出宏对象的持久化来源、展开语法及其相对于正则和 Lua 的精确内部顺序，因此不能进一步断言三者的优先级（`src/ts/process/index.svelte.ts:849-864, 900-1053`）。

桶的最终合成受模板卡片顺序控制，相邻同角色的 system 消息会合并；没有模板时按旧式分组顺序合成。拼装后才插入角色 `depth_prompt`，再运行 Lua `editRequest`，最后进行 token 重检。因而 depth_prompt 与 Lua 请求编辑面对的是已排序的结果，且后续预算可能清空可移除消息内容（`src/ts/process/index.svelte.ts:1235-1258, 1271-1523`）。

## 3. 请求层编译与模型可见结果

请求层的权威交接是 `sendChat` 传给 `requestChatData` 的最终消息数组。其形成前，角色描述可合并嵌入补充信息、人格与场景；记忆在模板含 memory 卡时以模板位置注入，否则包装为 `<Previous Conversation>`；start 脚本的附加提示可按 start、historyend、promptend 三个位置插入。模板槽位还可决定这些内容作为 user、assistant 或 system 发送（`src/ts/process/index.svelte.ts:466-496, 1169-1216, 1271-1468`）。

`requestChatData` 会先复制并反转义输入；每个回退模型和重试尝试前，依次运行插件 `replacerbeforeRequest` 与 request 触发脚本，后者可改写已拼装的数组，随后才进入 Provider 分发。Provider 分发前的 `reformater` 还会根据模型能力折叠或改写 system、合并连续角色或补 user 占位。因此，模板预览、模板配置和最终 Provider payload 不是同一证据层；本次可确认的模型可见中间结果是该函数收到并经这些请求前处理的数组（`src/ts/process/request/request.ts:205-272, 348-528`）。

工具目录同样在 `requestChatData` 开头取得，并作为各 Provider 的工具说明字段随请求携带。原笔记只确认这一注入点和 Provider 内的工具循环；工具的注册、筛选和执行语义不属于本专题（`src/ts/process/request/request.ts:205-346`）。

## 4. 消息生命周期变换与交接

输入消息进入本轮上下文前，角色房的用户输入先经过 editinput；选中的历史消息在编译时再经过 editprocess。这两处处理的结果影响本轮上下文，但原笔记没有确认它们是否回写原有权威消息，因此本专题只记录其请求前交接，不将其视为已确认的持久化改写（`src/lib/ChatScreens/DefaultChatScreen.svelte:144-216`；`src/ts/process/index.svelte.ts:900-1053`）。

请求开始前已经创建空的流式占位消息。每个流式块提供累计全文，消费端经 editoutput 后整体替换该消息的 data；因此 editoutput 的已确认结果是生成期间的消息写回。流结束后，output 触发脚本、inlay 屏幕、插件 chatOutput 监听与可选 TTS 顺序执行。output 脚本还能触发整轮重发，但原笔记未追踪其是否直接改写当前消息或具体重发时的规则再编译组合（`src/ts/process/index.svelte.ts:1591-1793`）。

流式消息修改会被全局保存循环以 500ms 防抖持续写盘，半截文本也会保存；`generationInfo` 和 `promptInfo` 随消息持久化。该持久化说明输出处理后的消息文本可成为后续历史来源，但不证明显示规则或请求规则会同步修改它（`src/ts/globalApi.svelte.ts:292-486`；`src/ts/process/index.svelte.ts:1530-1545, 1687-1753`）。

## 5. 显示层投影与消息渲染器交接

原笔记只确认正则脚本存在 editdisplay 模式，未追到该模式的调用位置、输入输出或 DOM 消费者。因此，不能确认它是否仅改变显示投影、是否改写权威消息，或是否参与模型请求。消息文本的 DOM 更新、滚动和流式重绘明确排除在原笔记的调查范围之外，应由消息渲染器类目继续追踪。

inlayViewScreen 的 emotion 与 imggen 指令在请求编译时会进入 postEverything 桶；而流结束后的 inlay 屏幕又属于生成后副链。两者同名相关能力处于不同阶段，现有证据不能将生成后的显示或异步行为倒推为模型输入（`src/ts/process/index.svelte.ts:560-580, 1761-1793, 1991-2190`）。

## 6. 调试、预览与可解释性

DevTool/快捷键提供 preview 模式，原笔记将其作为核对 `requestChatData` 实际收到数组的手段。该表面适合检查模板顺序、规则注入和请求前数组，而不能只凭编辑器配置判断实际携带内容（`src/ts/process/index.svelte.ts:654-708, 1273-1437`）。

请求日志通过 `addFetchLog` 带 chatId，可在 DevTool 查看；`chatProcessStage` 和 `doingChat` 提供生成阶段与忙碌状态，源码中散落的 `console.log` 还会输出完整 prompt 与记忆数据。这些是已确认的可观察入口。预览的实时性、是否展示 request 触发脚本和 reformater 之后的结果，以及日志的脱敏和保留策略，本次未验证（`src/ts/globalApi.svelte.ts:681, 1713`；`src/ts/process/index.svelte.ts:1530-1545`）。

## 7. 失败、更新与已确认边界

请求前 Lua `editRequest`、request 触发脚本与插件请求替换都可能处在重试或回退模型循环中；原笔记确认 request 触发脚本是每次尝试前执行，但没有记录脚本错误、变量缺失、循环替换或解析失败如何收口。start 脚本可用 `stopSending` 停止发送，这与 UI 中止是不同层级（`src/ts/process/index.svelte.ts:888-898`；`src/ts/process/request/request.ts:217-272`）。

已确认的边界是：普通固定系统提示、历史截断、记忆摘要、工具循环和 Provider 协议虽参与最终请求，却不都属于可编辑规则的编译语义。本笔记仅记录它们与规则结果的交接。原笔记未调查规则版本更新、迁移和导入导出，不能据此判断兼容策略。

## 8. 未验证事项

- 提示词模板、lorebook、触发脚本、Lua 与正则脚本的持久化 schema、版本、启停状态、编辑器行为和导入导出语义未由原笔记覆盖。
- lorebook 的实际命中、多个词条的冲突顺序、关键词/概率/冷却等条件，以及多位置组合的运行结果未实测。
- 宏的来源、变量缺失处理、精确展开顺序，以及其与正则和 Lua 的相互作用未确认。
- editdisplay 的实际消费位置、是否只投影显示、是否影响权威消息或请求，尚未追到。
- preview 模式与 request 触发脚本、Lua `editRequest`、`reformater` 及最终网络 payload 的时序关系未运行核对。
- output 脚本触发重发时，当前输出、持久化消息和新一轮规则编译的交接未逐行核对。
- 各 Provider 的实际网络行为、流式断流与重连、记忆引擎的长会话效果，以及情感和图片副链的实际触发行为均未实测。

## 9. 关键源码索引

- `src/ts/process/index.svelte.ts`：`sendChat`（99-2208）；规则桶建立（410-611）；模板预检（676-829）；start 脚本（888-898）；历史 editprocess（900-1053）；depth lorebook（1056-1066）；记忆与收尾桶（1068-1233）；模板拼装（1235-1497）；token 重检（1500-1523）；流式回写与生成后钩子（1591-1793）。
- `src/ts/process/lorebook.svelte.ts`：`loadLoreBookV3Prompt`（75-）。
- `src/ts/process/triggers.ts`：`runTrigger`（1058）；`src/ts/process/scriptings.ts`：`runLuaEditTrigger`（1409）；`src/ts/process/scripts.ts`：`processScriptFull`（99）。
- `src/ts/process/request/request.ts`：`requestChatData`（205-346）；`reformater`（348-432）；`requestChatDataMain` 与 Provider 分发（435-534）。
- `src/lib/ChatScreens/DefaultChatScreen.svelte`：`sendMain`（144-216）。
- `src/ts/globalApi.svelte.ts`：`saveDb`（292-486）；`globalFetch`（681）；`fetchNative`（1713）。
