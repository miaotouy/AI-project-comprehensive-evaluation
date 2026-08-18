# SillyTavern Agent 工具调查笔记

> 调查对象：`https://github.com/SillyTavern/SillyTavern`
>
> 调查更新日期：2026-07-30
>
> 代码快照：`8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8`（分支：`release`）
>
> 调查方式：只读源码梳理（`public/scripts/tool-calling.js`、`public/script.js`、`public/scripts/openai.js`、`public/scripts/extensions.js`、`src/endpoints/extensions.js`、`src/plugin-loader.js`、`default/config.yaml` 等），未修改被调查仓库
>
> 调查范围：模型可发现、请求并触发的工具，以及注册、执行、审批、安全边界与扩展入口
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

1. SillyTavern 的"Agent 工具"就是首次出现的 ToolManager（`public/scripts/tool-calling.js`）维护的浏览器侧函数注册表。工具由扩展或 STscript 的 `/tools-register` 在前端注册，随请求写入 OpenAI 兼容的 tools 字段，tool_choice 固定为 `'auto'`（无法强制/禁止调用单个工具）。
2. 仓库内置的、真正调用 `registerFunctionTool` 的只有**一个**工具：Stable Diffusion 扩展的 GenerateImage（`public/scripts/extensions/stable-diffusion/index.js:5457`）。其余工具均来自第三方扩展或用户通过 `/tools-register` 临时注册，代码层面找不到"内置工具清单"。
3. 调用循环没有任何逐次审批：模型返回 tool_calls 后立即等待 action，只弹出一个可关闭的 toast，不等待用户确认。
4. 递归上限默认值是 5（配置键 `oai_settings.tool_call_recurse_limit`，`public/scripts/openai.js:494`），但**用户可在设置面板把它调到 1～50**（`public/index.html:2021`,`2024`）；ToolManager 的递归上限还是可写的静态属性，扩展代码同样可以修改它。
5. STscript（slash command）与 Agent 工具之间存在一条重要旁路：`/tools-register` 允许把一个 **STscript closure** 注册为模型可调用的工具 action；工具执行时相当于以当前聊天上下文执行一段任意 STscript。这条路径把"模型输出 → 工具调用 → 执行代码"和"STscript 引擎能做什么"直接串联起来，扩大了工具的实际能力边界（可读写变量、调用几乎所有 slash command、发起网络请求等），详见维度 11。

## ASCII 调用链图

```text
[浏览器前端]
oai_settings.function_calling = true
  && main_api === 'openai'
  && custom_prompt_post_processing ∈ {NONE, MERGE_TOOLS, SEMI_TOOLS, STRICT_TOOLS}
  && ToolManager.isToolCallingSupported(settings, model)   // provider/model 白名单判定
        |
        v
ToolManager.tools .filter(await shouldRegister())
        |
        v
ToolManager.registerFunctionToolsOpenAI(generate_data)
  -> generate_data.tools = [...]; generate_data.tool_choice = 'auto'
        |
        v
POST /api/backends/chat-completions/generate  (服务端按 provider 转发/改写 tools 字段)
        |
        v
模型返回 tool_calls / tool_use / functionCall / cohere tool-call-* (流式或非流式)
        |
        v
ToolManager.#getToolCallsFromData()  归一化为 {id, function:{name, arguments}, signature}
        |
        v
ToolManager.invokeFunctionTools()
   for each call:
     toast.info('Invoking tool...')
     await ToolManager.invokeFunctionTool(name, parameters)   // JSON.parse(parameters) 无 schema 校验
       -> tool.action(parsedParams)                            // 扩展/浏览器 JS 或 STscript closure
     toastr.clear(toast)
        |
        v
非 stealth 结果 -> ToolManager.saveFunctionToolInvocations()
   -> chat.push(systemMessage) -> addOneMessage() -> saveChatConditional()
        |
        v
depth += 1; if depth < RECURSE_LIMIT(默认5, 可配 1~50): 重新调用 Generate('normal', ..., depth)
   否则停止递归（下一轮 canPerformToolCalls 判 false，不再注入 tools/执行工具）
```

依据：`../../SillyTavern/public/scripts/tool-calling.js:400-673`、`../../SillyTavern/public/script.js:4436`、`../../SillyTavern/public/script.js:5482-5500`、`../../SillyTavern/public/scripts/openai.js:2779-2781`。

## 维度 1：工具定义与注册

`ToolDefinition`（私有类，不导出）持有一组名称、描述、参数、执行动作、消息格式化、注册条件和隐身标志；ToolManager 的工具表是 `Map<string, ToolDefinition>`（单例静态字段，跨会话常驻，不随聊天切换重置）。

`registerFunctionTool({ name, displayName, description, parameters, action, formatMessage, shouldRegister, stealth })` 语义：

- `name`：Map 的 key。重复注册**直接覆盖**旧定义，只打印一条 `console.warn`，没有命名空间隔离，扩展 A 可用同名覆盖扩展 B 的工具（`tool-calling.js:275-277`）。
- `displayName`：仅用于 toast 文案和消息汇总标题，不参与 OpenAI 的函数名称字段。
- `parameters`：直接作为 JSON Schema 塞进函数参数，未经任何本地 schema 校验（见维度 4）。
- `action(parameters)`：异步执行动作，异常会被调用入口捕获并包装成带工具名的 Error。
- `formatMessage(parameters)`：可选，用于生成调用中的 toast 文案；缺省文案是“Invoking tool”。
- `shouldRegister()`：可选异步谓词，决定该工具是否进入本次请求的 tools 数组；每次生成请求都会重新求值，不是注册时求值一次。
- `stealth`：为 true 时结果不落入聊天消息、不触发后续生成（见维度 6/8）。

`unregisterFunctionTool(name)` 仅 `Map.delete`，无引用计数或依赖检查。

依据：`../../SillyTavern/public/scripts/tool-calling.js:239-304`

## 维度 2：工具发现与注入

`ToolManager.isToolCallingSupported(settings, model)` 的判定顺序：

1. `main_api !== 'openai'` → 直接 false（也就是说 Text Completion / KoboldAI / 各类非 Chat Completion 后端**完全不支持**函数调用）。
2. `settings.function_calling` 必须为 true（用户开关，界面位于 `#openai_function_calling`）。
3. `custom_prompt_post_processing` 必须属于 `{NONE, MERGE_TOOLS, SEMI_TOOLS, STRICT_TOOLS}`；其余后处理模式会把历史工具调用从 prompt 中强制剥除，视为不支持。
4. 若能在 `model_list` 中找到当前模型，则按 `chat_completion_source` 走**逐 provider 的模型元数据判定**（表见下）；否则落到步骤 5 的固定支持列表。
5. 固定支持列表包括 OpenAI、Claude、OpenRouter、Cohere、DeepSeek 等 provider（完整名称见源码中的列表）。

`canPerformToolCalls(type, settings, model)` = `isToolCallingSupported() && type ∉ {'impersonate','quiet','continue'}`。也就是说“旁白/静默生成/续写”这三种生成类型即使模型支持工具也不会触发工具调用/执行（但仍可能把 `tools` 字段带上，见下）。

注入点有两处，逻辑略有出入：
- `public/scripts/openai.js:1301-1307`：Prompt 组装阶段仅为**预留 token 预算**调用了一次 `registerFunctionToolsOpenAI(toolData)`（临时对象，不进最终请求体），随后按 `canPerformToolCalls(type)`（不区分 canMultiSwipe）预留 budget。
- `public/scripts/openai.js:2779-2781`：真正写入请求体的地方，条件是 `!canMultiSwipe && ToolManager.canPerformToolCalls(type, settings, model)`。**多重 swipe（`n>1`）时会跳过工具注册**。
- 服务端各 provider 分支（Claude/Google/OpenAI 兼容等，`src/endpoints/backends/chat-completions.js`）只是把 `request.body.tools` 原样转发/改写格式，不做二次的“是否该注入”判断，即前端一旦放入 tools 字段，服务端默认信任并转发。

stealth 语义：`isStealthTool(name)` 为 true 时，`invokeFunctionTools` 把该次调用名放入 `stealthCalls` 而不放入 `invocations`；`saveFunctionToolInvocations` 只处理非 stealth 的 `invocations`，因此 stealth 工具的调用**完全不写入 chat/不持久化/不触发后续生成**（`shouldStopGeneration` 判断里 `invocationResult.stealthCalls.length` 为真也会直接中止本轮递归）。

依据：`../../SillyTavern/public/scripts/tool-calling.js:608-688`、`../../SillyTavern/public/scripts/openai.js:1301-1307`、`../../SillyTavern/public/scripts/openai.js:2779-2781`

## 维度 2 附：provider 模型元数据判定表

| chat_completion_source | 判定字段 |
| --- | --- |
| POLLINATIONS | `currentModel.tools` |
| FIREWORKS | `currentModel.supports_tools` |
| OPENROUTER | `currentModel.supported_parameters?.includes('tools')` |
| MISTRALAI | `currentModel.capabilities?.function_calling` |
| AIMLAPI | `currentModel.features?.includes('openai/chat-completion.function')` |
| CHUTES | `currentModel.supported_features?.includes('tools')` |
| ELECTRONHUB | `currentModel.metadata?.function_call` |
| WORKERS_AI | `currentModel.properties` 数组中存在 `property_id==='function_calling' && value==='true'` |

以上仅当 `model_list` 里能找到该 `model.id` 时生效；找不到则回退到固定支持列表（见维度 2 正文）。

依据：`../../SillyTavern/public/scripts/tool-calling.js:623-643`

## 维度 3：模型调用表示与解析（逐家字段映射）

ToolManager 的响应解析器和流式增量解析器共同完成归一化，统一落到 `{id, function:{name, arguments}, signature?}` 形状。

| Provider/格式 | 原始形状 | 归一化处理 | 说明 |
| --- | --- | --- | --- |
| OpenAI 兼容（非流式） | `data.choices[i].message.tool_calls[]`，`{id, function:{name, arguments}}` | 直接取 `choice.index===0` 的 `message.tool_calls` | 若 `message.reasoning_details` 存在且类型为 `reasoning.encrypted`，把 `data` 写入 `toolCall.signature`（OpenRouter 专属） |
| OpenAI 兼容（流式） | SSE `choices[i].delta.tool_calls[]` 增量 | `#applyToolCallDelta` 按 `index` 定位到目标对象，字符串字段做**拼接**而不是覆盖 | `toolSignatures` 映射按 `id` 二次赋值到 `signature` |
| Claude `tool_use`（非流式） | `data.content[]` 中 `type==='tool_use'` 的 `{id, name, input}` | `convertClaudeToolCall`: `{id, function:{name, arguments: input}}` | `arguments` 是**对象**而非字符串（后续 `#parseParameters` 对非字符串直接透传） |
| Claude（流式） | `content_block` (`type==='tool_use'`) + `delta.type==='input_json_delta'` 的 `partial_json` 累积 + `content_block_stop` | 用内部 key `__input_json_delta` 累积字符串，`content_block_stop` 时 `JSON.parse` 一次性写回 `input` | 解析失败仅 `console.warn`，该次工具调用的参数会保持为空/不完整对象 |
| Google Gemini `functionCall`（非流式/AI Studio 专属） | `data.responseContent.parts[]` 或 `candidates[i].content.parts[]` 中 `part.functionCall = {name, args}` | `convertGoogleToolCall`: `{id: 随机, function:{name, arguments: args}, signature: part.thoughtSignature}` | id 是本地随机生成（`Math.random().toString(36)`），不是模型/服务端分配的稳定 ID |
| Google（流式） | 同上，作为一次性整块出现在 `candidates` 中（不是逐 token 增量） | 同上转换 | thoughtSignature 挂在 `signature` 字段，与 Claude/OpenRouter 共用同一个字段名 |
| Cohere（非流式） | `data.message.tool_calls`（对象或数组） | 数组化后直接使用，不做字段改名 | 假定其形状已经是 `{id?, function:{name, arguments}}` |
| Cohere（流式） | SSE `type ∈ {message-start, tool-call-start, tool-call-delta, tool-call-end}`，payload 在 `delta.message` | 走同一个 `#applyToolCallDelta` 增量合并管线 | index 取 `parsed.index ?? 0`，choiceIndex 固定为 0（不支持多 choice 并发工具调用流） |
| DeepSeek / 其他"固定支持列表"里的 provider | 服务端统一转成 OpenAI 兼容响应形状（见 `src/endpoints/backends/chat-completions.js` 各分支） | 走 OpenAI 兼容分支 | 前端 `tool-calling.js` 不区分 DeepSeek/Moonshot/xAI 等，靠服务端预先转码成同一形状 |

关键实现点：流式增量合并器对字符串字段是**追加拼接**，对象字段递归合并，空增量不会覆盖已有值。这是刻意的累积语义，但也意味着如果服务端某个分支重复发送同一个字段的完整值（而不是增量），会被错误地拼接两次；其中两个原型相关键被显式跳过以避免原型污染。

依据：`../../SillyTavern/public/scripts/tool-calling.js:427-757`

## 维度 4：参数校验与规范化

**没有任何 JSON Schema 校验**。parameters 字段只在注册工具时被当作不透明对象塞进函数参数；模型返回的实参经过参数解析器：

```js
static #parseParameters(parameters) {
    return parameters === ''
        ? {}
        : typeof parameters === 'string'
            ? JSON.parse(parameters)
            : parameters;
}
```

- 空字符串 → `{}`。
- 字符串 → JSON.parse，解析失败会抛出 SyntaxError，被调用入口捕获并包装为错误结果写回聊天消息（`error: true`），**不会中断整轮生成**，除非这是唯一一次调用且消息为空（见维度 5 的 shouldStopGeneration）。
- 已是对象（Claude/Cohere 某些路径）→ 直接使用，同样不做 schema 一致性检查。

也就是说，模型完全可以返回缺少 `required` 字段、类型不匹配、或包含 schema 未声明的额外字段的参数；这些校验责任被完全下放给各工具自己的 `action` 函数（如 SD 插件里手写的 `if (!args.prompt) throw ...`）。畸形/超范围参数的唯一"防线"是 JSON 语法本身是否合法，而不是内容是否合规。

依据：`../../SillyTavern/public/scripts/tool-calling.js:306-345`

## 维度 5：编排循环

递归上限：ToolManager 的递归上限是静态可写字段，默认赋值 5（`public/scripts/openai.js:494`），UI 滑块允许 1~50（`public/index.html:2014-2024`，`css/toggle-dependent.css:568` 控制该 UI 仅在 `function_calling` 打开时可见）。每次设置变化或加载 OpenAI 设置时都会同步写回该字段（`openai.js:4298`、`openai.js:6919`）。因此 5 只是默认值，不是硬编码上限：滑块把 UI 可配置范围限制在 1~50，但字段本身可被任意代码或扩展改写为任意数字，包括 `Infinity`。

实现点：`public/script.js:4436`
```js
const canPerformToolCalls = !dryRun && ToolManager.canPerformToolCalls(type) && depth < ToolManager.RECURSE_LIMIT;
```
深度由调用方传入，递归时加一后重新调用普通生成（`public/script.js:5497-5499`，流式分支同理 `public/script.js:5373-5376`）。当深度达到递归上限时，工具调用条件变为 false，本轮不再注入 tools 字段（`openai.js:2779`）也不再执行工具，模型只能返回普通文本作为终止。

调用顺序（串行，非并行）：工具调用循环按模型返回顺序逐个等待 action（`tool-calling.js:787-841`），**没有 `Promise.all` 并发**。因此同一轮内前一个工具的副作用（例如改写聊天变量）会在下一个工具执行前生效。

错误处理与提前终止条件（`shouldDeleteMessage` / `shouldStopGeneration`）：
- 若本轮 assistant 消息文本为空/`'...'`且没有 reasoning，且这是非 swipe 类型，则先删除刚创建的空消息（`deleteLastMessage()`），避免留下空气泡。
- 停止条件是“没有非 stealth 的有效调用记录且消息本应删除”，或“本轮触发了任意 stealth 工具”；命中后直接停止本轮生成流程，不进入递归（`unblockGeneration`）。
- 否则，只要存在工具调用且不满足停止条件，就增加深度、保存工具调用系统消息并递归执行普通生成，从而让模型看到工具结果继续生成。这构成事实上的自动多轮 Agent 循环，直到达到递归上限或模型不再发起新的 tool_calls。

工具结果如何写回：见维度 8。是否影响 chat 持久化：见维度 8（`saveFunctionToolInvocations` 内部会 `saveChatConditional()`，即落盘）。

依据：`../../SillyTavern/public/script.js:4436`、`../../SillyTavern/public/script.js:5349-5378`、`../../SillyTavern/public/script.js:5482-5500`、`../../SillyTavern/public/scripts/openai.js:494`,`4298`,`6919`、`../../SillyTavern/public/index.html:2014-2024`

## 维度 6：审批与策略

调用链里没有逐次用户审批。整条链路里唯一的用户可见反馈是：

1. 调用开始：显示一条不会自动消失、但也**不含任何“允许/拒绝”按钮**的信息 toast，纯展示用途（`tool-calling.js:799`）。
2. 调用结束：直接清掉提示，此时调用早已完成。
3. 出错时：弹出一个可点开详情的错误 toast（`tool-calling.js:916-921`），但这是**调用之后**的事后提示，不能阻止已发生的执行。

没有找到任何形式的：
- 逐次确认弹窗（`Popup.show.confirm` 未在 `tool-calling.js` 中出现）。
- per-tool 的启用/禁用开关。
- 全局"Agent 模式/自动执行模式"开关来分级放行不同风险的工具。

现有的唯二"策略点"实际上是产品设置，不是审批：
- `oai_settings.function_calling`（总开关，打开则该会话所有已注册工具默认可用）。
- 每个工具自己的注册条件（例如 SD 扩展在 `extension_settings.sd.function_tool` 为 false 时直接注销工具），这是**开发者/用户在扩展设置里预先决定“是否让模型看到这个工具”**，而不是运行时逐次审批。

`stealth` 工具的效果不是"跳过审批"而是"跳过展示与持久化并阻断该轮的后续生成"，其本质仍是无审批自动执行。

SillyTavern 的信任模型完全建立在"是否安装/启用某扩展"这一步骤上：一旦扩展注册了工具且用户打开了函数调用开关，模型对该工具的每一次调用都会立即执行，没有运行期二次拦截。

依据：`../../SillyTavern/public/scripts/tool-calling.js:796-921`、`../../SillyTavern/public/scripts/extensions/stable-diffusion/index.js:5452-5455`

## 维度 7：执行位置与隔离

浏览器前端 `action`：运行在与 SillyTavern 主页面**同一个 JS 执行上下文**里（没有 iframe/Worker/沙箱隔离），因此能力等价于当前登录会话在浏览器里能做的一切：

- 可直接调用 getContext（`st-context.js`）暴露的几乎全部内部 API：聊天数组读写、保存聊天、生成请求、执行 slash command、变量读写、World Info、角色和群组 API，以及宏求值等。
- 可发起任意 `fetch()`，包括访问本服务端的其他 `/api/...` endpoint（受浏览器同源 Cookie/CSRF token 约束，与用户手动点击按钮发出的请求同权），也可以对**第三方域名**发起跨域请求（受目标站点 CORS 策略约束，但很多只读 GET 请求不受 CORS 限制）。
- 可以执行任意 slash command，从而间接获得整套 STscript 能力（见维度 11）。
- 唯一的边界是浏览器同源策略和 CSRF token（服务端默认开启 CSRF 保护，`default/config.yaml:180 disableCsrfProtection: false`），以及该用户账号自身在多用户模式下的权限（例如 `request.user.profile.admin` 决定能否操作 global 扩展/插件目录，但这是服务端 REST 层面的限制，与"工具 action 能调用什么"无关——工具 action 本身运行在已登录用户的浏览器会话里，天然具有该用户的全部权限）。

服务端 plugin（`src/plugin-loader.js`）：完全不同的信任域——是 Node.js 进程内代码，通过 `import()` 动态加载 `plugins/` 目录下的模块，`init(router)` 拿到一个 Express Router 挂载到 `/api/plugins/{id}`。这意味着服务端 plugin：

- 拥有完整的 Node.js 权限（文件系统、子进程、网络、环境变量），不存在任何权限收窄机制。
- 默认关闭（`enableServerPlugins: false`），需要显式在 `config.yaml` 打开。
- **服务端 plugin 与浏览器工具是两条独立的机制**：工具管理器完全在浏览器侧运行，插件加载器完全在服务端运行，二者没有直接的代码耦合；一个服务端 plugin 要参与“模型可调用的工具”，必须自己再暴露一个 HTTP endpoint，然后由某个浏览器扩展通过注册函数工具把该 endpoint 包装成工具（间接组合，不是内建机制）。

两者的差异总结：浏览器 action 的执行权限范围是"当前登录用户在该浏览器会话里能做的一切"，服务端 plugin 的执行权限范围是"运行 SillyTavern 服务端进程的操作系统账户能做的一切"，后者影响面更大，但启用它需要管理员显式开启配置项并信任已安装的插件代码。

依据：`../../SillyTavern/public/scripts/st-context.js:114-186`、`../../SillyTavern/src/plugin-loader.js:40-231`、`../../SillyTavern/default/config.yaml:180`,`392-394`

## 维度 8：结果处理与回注

工具调用入口的返回值规则是：字符串结果原样返回，非字符串结果转成 JSON，出错时返回一个带工具名的 Error 实例而不是继续抛出。**没有发现结果长度截断逻辑**，一个工具可以返回任意大的字符串，该字符串会被完整塞进：

1. 一条新的系统消息（HTML，包含 details、summary、pre 和 code 结构；参数与结果经过解析后写入 textContent，而不是 innerHTML，因此这一步本身不引入 HTML 注入）。
2. 消息的 `extra.tool_invocations` 结构化数组，其中含调用标识、名称、参数、结果、错误、签名和推理信息；该数组之后会被核心聊天过滤逻辑重新纳入下一轮 prompt（`public/script.js:4437`），即**工具调用记录会持续留在聊天历史里参与后续所有请求的上下文**，除非用户手动删除该系统消息或关闭函数调用开关。

持久化：保存工具调用结果的流程依次把消息加入聊天、发出完成事件、加入 DOM、发出渲染事件，最后保存聊天（见消息渲染器笔记）。也就是说**工具调用结果会被写入磁盘上的聊天记录**，与普通消息同等持久化。

上下文污染面：由于结果原样进入 prompt 且无截断或内容过滤，一个恶意或错误的工具可以把任意大小、任意内容的文本注入后续所有轮次的模型上下文，构成间接提示注入放大器。模型编造不存在的工具名时，界面先显示兜底文案，之后才在真正执行阶段报错。

依据：`../../SillyTavern/public/scripts/tool-calling.js:319-345`、`../../SillyTavern/public/scripts/tool-calling.js:859-909`、`../../SillyTavern/public/script.js:4437`

## 维度 9：内建/自带工具与扩展工具清单

以搜索注册函数工具的实际调用位置为准（不含工具管理器内部定义和 `st-context.js` 的 API 暴露本身）：

| 工具名 | 来源 | 触发/注册条件 | 用途 | 执行位置 | 风险点 |
| --- | --- | --- | --- | --- | --- |
| `GenerateImage` | 内置扩展 `stable-diffusion`（`public/scripts/extensions/stable-diffusion/index.js:5452-5484`） | `extension_settings.sd.function_tool === true` 时注册，否则注销 | 让模型按文本 prompt 触发出图 | 浏览器前端：调用图像生成函数，进而向配置好的 SD/DALLE/Comfy 等图像后端发起请求 | 执行动作只检查状态有效和 prompt 存在，不校验 prompt 内容；出图请求会打到用户在设置里配置的图像生成后端（可能是本机 SD WebUI、第三方付费 API 等），模型可诱导用户消耗额度或探测该后端的可达性 |
| 用户临时注册的工具 | STscript `/tools-register`（`public/scripts/tool-calling.js:988-1137`） | 用户/QuickReply/角色卡内嵌的 slash command 主动执行一次注册命令 | 任意场景，取决于用户或 QuickReply 预设写的 closure | 浏览器前端：action 是一段 STscript closure，等价于执行任意 slash command 序列 | 若该注册命令本身来自角色卡首条消息、World Info 或可被远程更新的 QuickReply 预设，则内容本身即可定义模型可调用的工具（见维度 11.3） |
| 第三方扩展自定义工具 | 任意通过 Git 安装的 `third-party/*` 扩展 | 该扩展 JS 主动调用注册函数工具的方法（`st-context.js:182`） | 取决于扩展 | 浏览器前端，与该扩展其余代码同权 | 完全取决于对该扩展的信任；没有任何运行时沙箱区分“这段代码是工具 action”还是“这段代码是普通 UI 逻辑” |

依据：`../../SillyTavern/public/scripts/extensions/stable-diffusion/index.js:5452-5484`、`../../SillyTavern/public/scripts/tool-calling.js:988-1137`、`../../SillyTavern/public/scripts/st-context.js:182-186`

## 维度 10：扩展机制

**浏览器扩展的 manifest 与动态加载：**

- `manifest.json` 通过 `fetch('/scripts/extensions/{name}/manifest.json')` 拉取（`extensions.js:543`），字段包括 `js`/`css`/`loading_order`/`requires`/`dependencies`/`minimum_client_version`/`generate_interceptor`/`hooks`。
- `activateExtensions()` 校验 `requires`（Extras 模块子集）、`dependencies`（其他扩展未禁用）、`minimum_client_version` 后，用 `import(url)`（`url = /scripts/extensions/{name}/{manifest.js}`）动态加载 JS 入口（`extensions.js:813-819`），加载后调用生命周期 hook `activate`（若 manifest 声明了 `hooks.activate`）。
- `generate_interceptor`：manifest 可声明一个全局函数名，`runGenerationInterceptors` 在每次生成前按 `loading_order` 排序依次调用 `globalThis[interceptorKey](chat, contextSize, abort, type)`，可修改 `chat`/中止生成（`extensions.js:2015-2038`）。这本身不是"Agent 工具"（模型不可见、不经过 tool_calls），但是另一条扩展可以无审批干预生成流程的通道，值得在与 Agent 工具对比时区分开。

**第三方 Git 安装流程：**

- 客户端 `installExtension(url, global, branch)`（`extensions.js:1698-`）：校验 URL protocol 只能是 `http:`/`https:`；若不是 `isOfficialExtension(url)`（正则 `^https://github.com/SillyTavern/(.+)$`），弹出一次性可勾选"不再提醒"的信任警告 `Popup.show.confirm`，用户确认后才继续；确认状态用 `accountStorage`（浏览器本地存储）持久化，之后不再提示。
- 服务端 `POST /api/extensions/install`（`src/endpoints/extensions.js:92-156`）：二次校验 URL protocol；用 `sanitize-filename` 库净化从 URL 提取的目录名（`extensionNameSanitized = sanitize(path.basename(parsedUrl.pathname, '.git'))`）防止路径穿越；用 `simple-git`（可切换 `git.backend`）`clone(url, extensionPath, {depth:1, branch})`；安装 `global` 扩展需要 `request.user.profile.admin`。
- `enableServerPluginsAutoUpdate`（默认 true）会在服务器启动时对 `plugins/` 下所有 git 仓库自动 `fetch`+`pull`，**不做任何"这是否是官方仓库"的判断**，纯粹按目录是否是 git repo 来决定是否自动更新，这意味着一旦装了不可信插件，其上游仓库后续推送的任意代码都会被自动拉取并在下次重启时被 `import()` 执行。

**服务端 plugin 的 `import()` 加载：**

- `loadPlugins(app, pluginsPath)` 默认 `enableServerPlugins: false`；打开后扫描 `plugins/` 目录，支持单文件（`.js/.cjs/.mjs`）或带 `package.json`/`index.js` 的目录形式；用 Node `import(fileUrl)` 动态加载后要求导出 `info{id,name,description}` 和 `init(router)` 函数，`id` 仅做正则 `^[a-z0-9_-]+$` 校验（防止路由路径注入），不做代码签名/来源校验。
- `console.log` 会在加载完成后明确打印警告："Make sure you know exactly what they do, and only install plugins from trusted sources!"——这是代码里唯一的"信任提示"，且只出现在服务端日志，不会展示给最终用户。

**默认 `config.yaml` 中与暴露面相关的项：**

| 配置项 | 默认值 | 含义 |
| --- | --- | --- |
| `listen` | `false` | 默认只绑定本机，不对外监听 |
| `whitelistMode` | `true`，`whitelist: [::1, 127.0.0.1]` | 默认仅本机可访问（若手动开启 listen） |
| `basicAuthMode` | `false` | 默认不需要额外密码层 |
| `disableCsrfProtection` | `false` | 默认启用 CSRF 保护 |
| `securityOverride` | `false` | 默认启用启动期安全检查 |
| `privateAddressWhitelist.enabled` | `false` | 默认**不**阻止服务端出站请求打到内网私有地址（SSRF 缓解默认关闭，仅在 `listen` 模式或对外暴露时才建议打开，注释里也这样写） |
| `enableServerPlugins` | `false` | 默认关闭服务端插件 |
| `enableServerPluginsAutoUpdate` | `true`（但仅在插件已启用且已安装时才有意义） | 插件仓库自动拉取更新 |

这些配置共同决定的是"谁能访问这个 SillyTavern 实例、能不能通过网络打到内网"，而不是"已安装的扩展/插件能做什么"——一旦通过身份验证进入前端，Agent 工具执行链路上没有额外的按配置项收窄的权限点。

依据：`../../SillyTavern/public/scripts/extensions.js:400-466`,`568-646`,`813-819`,`1698-1740`,`2015-2038`、`../../SillyTavern/src/endpoints/extensions.js:92-156`、`../../SillyTavern/src/plugin-loader.js:40-90`,`179-231`,`237-293`、`../../SillyTavern/default/config.yaml:6`,`59-70`,`154-182`,`392-394`

## 维度 11：STscript / slash command 与 Agent 工具的关系

STscript 是 SillyTavern 工具面的最大非显式扩展路径。

### 11.1 模型输出能否直接触发 slash command？

**不能直接触发**。命令处理器只在用户主动发送消息时被调用（`public/script.js:4252`，入口是“用户点击发送按钮”），并以消息是否以 `/` 开头作为判断条件（`script.js:3067`）。模型的 AI 回复经由保存、格式化和 DOMPurify 等渲染管线处理，这条路径不会执行 slash command 解析器（见消息渲染器笔记）。

### 11.2 `/tools-register` 把 STscript 注册为工具

**已在代码中确认**（`tool-calling.js:988-1137`）：`/tools-register` 接受一个 **STscript closure** 作为 action 参数，执行时：

1. 把 closure 包装成异步函数。
2. 工具被模型调用时，该 closure 的作用域会接收模型传来的参数（以 arg.xxx 形式注入为宏变量，`tool-calling.js:62-74`）。
3. 执行这段 closure，结果通过管道作为工具返回值回给模型。

这意味着：任何 STscript 能做的事情，都可以通过 `/tools-register` 变成模型可调用的工具。STscript 的能力包括（已在代码中确认的 slash command 子集）：

- `/gen` `/genraw`：静默调用模型生成，实现"工具嵌套生成"；
- `/trigger`：触发指定群成员生成，构成群聊链式调用入口；
- `/send` `/sys` `/sendas`：向聊天注入消息，可伪造任意角色的发言；
- `/run`：执行 Quick Reply，进一步扩展代码范围；
- `setvar/setglobalvar/getglobalvar` 等变量宏/命令：读写全局持久变量；
- `/inject`：向 prompt 注入额外指令文本（`/listinjects`/`/flushinject`）；
- `/api-url`/`/connect` 等连接管理：修改 API 端点、切换模型；
- 通过 `fetch()` 或调用 ST 自己的后端 endpoint 完成几乎任意的 HTTP 请求（STscript 中可以通过 slash command 调用内置扩展如 `memory`、`vector` 等，这些扩展本身会发起网络请求）。

**未发现**任何机制阻止"通过 `/tools-register` 注册的工具 closure 里调用敏感 slash command"，也未发现针对 STscript closure action 的权限降级或命令白名单。

### 11.3 Quick Reply 自动执行与工具的交叉

Quick Reply 扩展（`public/scripts/extensions/quick-reply/`）监听角色消息渲染事件（`index.js:292`）并执行自动处理函数，后者遍历所有设置了 `executeOnAi=true` 的 QR 并按顺序执行其 message（即一段 STscript），这是一条与 Agent 工具**并行但独立**的自动化路径：

- 每次 AI 消息生成完毕后都会触发，与消息内容无关。
- 若某个 `executeOnAi` 的 QR 里调用了注册函数工具的方法（通过 getContext 或直接调用），它可以在每次 AI 回复后动态修改注册表，例如根据最新消息内容条件性地注册不同工具。
- World Info（lorebook）的 `automationId` 字段可在某个词条被激活时触发 QR（`world-info.js:902` emit `WORLD_INFO_ACTIVATED` → `quick-reply/index.js:302` → `handleWIActivation`）。这意味着：**角色卡或 World Info 内容一旦被激活，就能触发 STscript 执行，而不需要借助 tool_calls**。这是一条完全独立于函数调用机制的、"内容驱动的代码执行"路径。

结合 11.2：`/tools-register` 对 action closure 的来源没有任何限制（`tool-calling.js:988-1137`），因此上述内容驱动的 STscript 执行若包含 `/tools-register` 命令，即可注册或覆盖模型可调用的工具定义。

### 11.4 宏展开是否发生在 tool action 结果上？

工具结果写入消息的是原始 HTML（由 DOM API 拼装，文本节点写入，不做宏展开）；消息进入格式化流程时会经历正则处理，但工具调用消息标记为系统消息（`tool-calling.js:894`），因此被判断为“allow markdown but skip regex”（`script.js:1774-1777`），**不会触发 regex 脚本**，宏展开也不会再次处理其内容。

进入下一轮 prompt 时，工具调用消息被核心聊天过滤逻辑重新包含；由于它仍是系统消息，宏和正则处理继续跳过，所以模型最终看到的工具结果是**原始文本**。

依据：`../../SillyTavern/public/scripts/tool-calling.js:988-1163`、`../../SillyTavern/public/scripts/slash-commands.js:3066-3074`,`2578-2604`、`../../SillyTavern/public/scripts/extensions/quick-reply/src/AutoExecuteHandler.js:57-60`,`85-103`、`../../SillyTavern/public/scripts/world-info.js:902`、`../../SillyTavern/public/script.js:3066-3074`,`4252`,`1774-1777`

## 维度 12：子 Agent 与任务委派

**未找到内建的"子 Agent"或"委派"机制**。但有几个路径可以构成事实上的自主循环：

1. **函数调用递归**（已在维度 5 描述）：在深度小于递归上限时进行普通生成的尾调用。每个递归轮次就是一次完整的模型请求，模型可以再次发起 tool_calls，实现链式 Agent 行为，这是代码中最直接的“Agent 循环”实现。
2. **群聊自动模式**（`group-chats.js:139-187`）：定时轮询并让不同角色轮流生成消息，这是“自主循环”的时间驱动来源；若群聊成员有工具调用能力，则每轮触发的生成都可能进入函数调用递归。
3. **`/trigger` slash command**（`slash-commands.js:1805-1833`）：在 STscript 中等待另一个角色生成完毕，构成同步的“委派给另一个角色”效果，但仍在同一浏览器页面里执行，不是真正的跨进程 agent。

**未发现**：
- 明确的"任务队列"或"Agent 池"抽象。
- 跨会话的持久任务状态（工具结果写入 chat 历史，但聊天结束后不会主动重启执行）。
- 真正的并行子 agent（所有调用仍在单一浏览器 tab 的 JS 主线程上）。

依据：`../../SillyTavern/public/scripts/group-chats.js:117-187`、`../../SillyTavern/public/scripts/slash-commands.js:1805-1833`

## 维度 13：与消息渲染器调查笔记的交叉点

参照 `../消息渲染器/SillyTavern-消息渲染调查笔记.md`，交叉点集中在“工具调用结果如何呈现”和“模型能否用文本伪造出工具调用的视觉/语义效果”两个问题上。

### 13.1 工具调用如何呈现

渲染器笔记第 106、109 行已指出：工具调用数组只是标记该消息，消息层没有独立的工具卡组件，只是给消息元素增加 toolCall class，且纯工具调用且无正文或推理时还会暂时隐藏消息。本次工具调查确认了生产端：保存函数生成的消息是一段手工拼装的 details HTML（`tool-calling.js:864-881`），角色是系统用户并标记为系统消息。这段 HTML 经由标准消息装配流程渲染，**不会经过 Showdown/正则管线**。

结果内容经解析后通过 textContent 写入（`tool-calling.js:875`），这是安全的文本节点赋值，不会被当成 HTML 解析，因此参数或结果中即使包含脚本标签也不会在这一步造成 XSS。但外层 details 结构通过 outerHTML 输出后再赋给消息，系统消息是否还会经过一次 DOMPurify 取决于消息更新流程的具体分支；本次未逐行验证，**标记为需进一步验证**。

### 13.2 模型能否用文本伪造工具调用外观

**可以从纯视觉/文本层面伪造,但不会被当作真实工具调用处理**。原因:

- 真正的工具调用识别完全依赖 `ToolManager.#getToolCallsFromData(data)` 从**结构化的 API 响应字段**(`choices[].message.tool_calls`、Claude `content[].type==='tool_use'` 等)中提取,不从 assistant 消息的纯文本内容里做任何模式匹配。模型在**普通回复正文**里写出"看起来像"工具调用 JSON 的文本(例如伪造一段 `<details><summary>Tool calls: FakeTool</summary>...`)只会被当作普通 Markdown/HTML 走渲染器笔记描述的常规管线(DOMPurify、regex、Showdown),不会触发 `invokeFunctionTools`,也不会被系统认成"工具调用消息"(没有 `extra.tool_invocations`、没有 `toolCall` class)。
- 但这种伪造**可以骗过人类读者**:如果模型输出的 HTML/Markdown 精确模仿了 `#formatToolInvocationMessage` 的 `<details>` 结构样式,普通用户在 UI 上可能无法一眼分辨"这是系统生成的真实工具调用记录"还是"角色在正文里编造的假记录"。DOMPurify 会清洗掉危险标签/属性(参见渲染器笔记"HTML 净化与 CSS"节),但保留的 `<details>/<summary>/<pre>/<code>` 结构完全合法,不会被过滤掉。
- 反向路径:一个真实的工具结果(`toolResult`)如果本身是攻击者可控的字符串(例如恶意工具返回精心构造的文本),会被 `JSON.stringify`/`tryParse` 后原样展示,同样存在"结果内容欺骗用户,让其误以为是可信的工具输出"的风险,这属于维度 8 提到的"上下文污染面"与本节"视觉伪造"的交集。

**结论**:工具调用的真实性判定在数据层是可信的(只信任结构化 API 字段),但在展示层没有任何"来源标记"(如签名、专属图标、不可被常规消息内容覆盖的固定 UI 位置)与模型可自由输出的普通消息 HTML 做区分,存在社会工程学层面的欺骗空间,不构成代码执行层面的权限绕过。

依据:`../../SillyTavern/public/scripts/tool-calling.js:859-909`、`../../SillyTavern/public/script.js:2559`(单条消息装配,参见渲染器笔记"单条消息装配"节)、`../消息渲染器/SillyTavern-消息渲染调查笔记.md` 第 106-109 行、第 245-274 行(HTML 净化与 CSS)

## 维度 14：未验证事项与后续调查缺口

1. **系统消息(`is_system:true`)是否豁免/部分豁免 DOMPurify**:工具调用消息本身是系统生成的可信 HTML,但没有在代码中确认 `updateMessageElement()` 对 `is_system` 消息走的净化分支是否与普通 AI 消息完全一致。若存在豁免,而某个工具的 `action` 返回值被拼进了系统消息的其他字段(目前看只有 `tryParse` 后的 `textContent` 赋值,风险较低),需要针对性复核。
2. **"模型输出文本被自动当作 slash command 执行"的具体实现是否存在于某些常用第三方扩展/QuickReply 预设中**:核心代码未发现此类"回填"逻辑,但笔记只覆盖了仓库自带代码,未逐一审查生态里下载量较高的第三方扩展/QR 预设包是否自行实现了"读取 AI 回复文本 → 交给 `executeSlashCommandsWithOptions`"的功能。
3. **角色卡/世界书导入流程是否会让内嵌的 QuickReply(含 `automationId`/`executeOnAi`)默认处于"自动执行"状态**,还是需要用户在导入后手动勾选/信任——本次未走查角色卡导入 UI 与 QuickReply 设置的默认值联动逻辑。
4. **`simple-git`/`createGitClient` 在扩展安装、扩展/插件自动更新时发起的网络请求是否受 `privateAddressWhitelist` 保护**,即"服务端 Git 安装/更新"是否可以被用作对内网地址的 SSRF 探针。笔记只确认了该配置项默认关闭且注释建议在暴露场景下开启,未验证 Git 客户端调用链是否复用了该 whitelist 的检查逻辑。
5. **`ToolManager.RECURSE_LIMIT` 被扩展代码恶意写成极大值或 `Infinity` 后的实际行为**:理论上会导致无限递归 `Generate` 调用直至浏览器卡死/API 额度耗尽,但未做运行时验证(例如是否有其他隐性的调用栈/内存限制会先触发浏览器崩溃或异常终止)。
6. **多用户模式(`enableUserAccounts`)下扩展安装、QuickReply 预设、World Info 是否存在用户间隔离缺口**,超出本次"Agent 工具"调查范围,建议单独立项。
7. **DeepSeek、Moonshot、xAI 等"固定支持列表"内 provider 的服务端响应转码是否与 OpenAI 格式完全一致**:本次仅确认 `src/endpoints/backends/chat-completions.js` 存在按 provider 分支处理 `tools` 字段的代码,未逐一给每个 provider 做请求/响应抓包验证,标记为"文档/代码结构上合理但未端到端验证"。
8. **`callExtensionHook` 的 5 秒超时(`extensions.js:447-459`)对 `activate`/`enable`/`disable` 等 hook 的实际影响**:超时只是打印警告,不阻止/回滚已发生的副作用,若某扩展的 `activate` hook 本身在超时后仍继续异步执行并注册了工具,是否会造成"注册时机不确定"的竞态,未做验证。

依据:本节为待验证问题清单,具体代码位置见各自对应维度小节。
