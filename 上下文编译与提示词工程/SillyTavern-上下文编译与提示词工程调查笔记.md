# SillyTavern 上下文编译与提示词工程调查笔记

> 调查对象：`https://github.com/SillyTavern/SillyTavern`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8`（分支：`release`）
>
> 调查方式：复用对话请求与上下文调查笔记已确认的源码阅读结果，覆盖 `Generate()` 主链、正则引擎、宏替换、World Info、扩展提示词、生成拦截器与 OpenAI 消息组装的已定位消费点
>
> 调查范围：规则对象在一次生成中的选择、展开、排序与请求/消息/显示层去向；不重新调查规则编辑器、持久化与导入导出、会话数据模型、Provider 传输、渲染实现和各规则的完整运行命中行为
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

SillyTavern 的上下文编译不是单一的 prompt 模板处理器。一次生成在 `Generate()` 中依次对历史消息应用 prompt 用途的正则、补入角色字段与 depth prompt、扫描并按位置注入 World Info、合并 system/jailbreak/story string/chat inject 等内容，再按 text completion 或 OpenAI 两条链路转换并裁剪，最终形成 `finalPrompt` 或 OpenAI 消息数据。最终请求仍可被 `GENERATE_AFTER_COMBINE_PROMPTS` 事件监听器整体替换，因此配置或中间分项存在不等于本次请求实际携带（`public/script.js:4401-5257`）。

已确认的规则结果有三条去向：`promptOnly` 正则只影响 prompt 组装；无标记正则还会在生成后清洗回复并写回权威消息；`markdownOnly` 正则只进入显示格式化。宏也不是统一的预编译阶段，而是在用户消息、首条问候语、bias、quiet prompt 和正则替换等各自路径分别展开。World Info 和扩展 prompt 的实际命中内容进入上下文拼装，生成拦截器则在组装早期按 manifest 顺序运行并可中止本次生成。

## 系统边界与规则编译主链

本笔记只记录可影响提示词、权威消息或显示投影的规则对象及其交接。生成提交、Provider 调用、流式消费、停止与重试留在“对话请求与上下文”；消息 schema 与持久化细节留在“会话与消息管理”；Markdown、DOM 和流式重绘留在“消息渲染器”。

```text
Generate()
  -> slash command 整段拦截或继续
  -> 角色字段与 depth prompt
  -> 筛选后的历史逐条执行 prompt 用途正则、附件和标题处理
  -> World Info 扫描，按位置写入 extension prompts
  -> system / jailbreak / story string / chat inject
  -> 角色转换为 text completion 历史或 OpenAI messages
  -> 预算裁剪与合并为 finalPrompt 或 OpenAI 请求消息
  -> GENERATE_AFTER_COMBINE_PROMPTS 允许扩展替换整体 prompt
  -> Provider 数据构建
```

`Generate()` 开始时先执行 `processCommands()`；以 `/` 开头且被判为打断的输入会直接短路，不进入后续上下文编译。其后历史筛选排除 `is_system` 消息，但在工具可用时保留带 `extra.tool_invocations` 的 system 消息。单聊与群聊均回到这一生成函数完成实际编译，群聊包装器负责选择成员并串行调用它（`public/script.js:4231-4440`；`public/scripts/group-chats.js:945-1092`）。

## 1. 规则对象、权威源与作用域

原笔记已定位到以下参与编译或投影的对象，但没有覆盖它们各自的配置 schema、持久化位置、版本、启停字段及导入导出语义：

| 对象 | 已确认的作用域或选择面 | 已确认的消费结果 |
|---|---|---|
| 正则脚本 | 按消息类型选择用户输入或 AI 输出位置；另有 reasoning 位置 | prompt 组装、生成后清洗或 Markdown 显示，取决于脚本标记 |
| 宏 | 调用它的局部文本路径 | 替换用户消息、首条问候语、bias、quiet prompt 或正则替换中的参数 |
| World Info | 由当前聊天的名称与正文构成的反向数组扫描；扫描结果带位置 | 作为 before、after、depth、example 或 outlet 等位置的 extension prompt 注入 |
| 扩展 prompt | 由扩展更新的具名槽位 | 与其他分项一起进入 prompt 合并和 itemized prompt 记录 |
| 生成拦截器 | 已注册的扩展全局函数，按 manifest 顺序 | 在主链早期调整上下文或中止生成 |

角色卡字段由 `getCharacterCardFields()` 读取，description、personality、scenario、examples、system 与 jailbreak 等内容参与后续拼装；角色或群聊的 depth prompt 则作为 extension prompt 注入。原笔记确认了这些字段的读取与注入点，未覆盖其编辑、保存、导入导出和更细的角色、预设或群组选择语义（`public/script.js:4401-4427`）。

World Info 的选择入口是 `getWorldInfoPrompt(chat, this_max_context, ...)`。传入内容是带名称和正文的反向聊天数组，扫描结果被分派到多个注入位置；非 dry run 时还会发出 `WORLD_INFO_ACTIVATED`。本次依据没有展开关键词、概率、白名单、冷却、同名冲突或多个条目的排序规则（`public/script.js:4564-4622`；`public/scripts/world-info.js:892-915`）。

## 2. 选择条件、优先级与编译顺序

已确认的主链顺序以 `Generate()` 的实际调用顺序为准，而不是设置界面或预览：

1. slash command 可在取输入前劫持整段发送流程。
2. 生成前读取角色字段与 depth prompt，并对首条问候语执行宏替换。
3. 筛选历史后，逐条按用户输入或 AI 输出位置执行 `isPrompt: true` 的正则，再展开附件文本、附加标题，并为 reasoning 应用其专用正则。
4. 运行生成拦截器；拦截器按 manifest 顺序执行，任一拦截器调用 `abort(true)` 会停止后续拦截器和本次生成。
5. 扫描 World Info，并将结果按 before、after、depth、example 与 outlet 等位置注入 extension prompts。
6. 处理 system prompt、jailbreak、story string 和 chat inject，随后转换角色或消息格式。
7. 按 API 类型执行预算裁剪并组合；text completion 得到 `finalPrompt`，OpenAI 走自己的消息准备路径。
8. 在合并前后分别发出事件；合并后事件的扩展可替换完整 prompt，随后才构建 Provider 数据。

该顺序说明正则的 prompt 处理发生在 World Info 与系统字符串拼装之前，而最终 prompt 并非不可变产物。text completion 的历史从最新消息向前累积，优先预分配注入消息，超限后还会先丢示例、再丢最旧消息并递归重试；OpenAI 的预算入口和超限报错已确认，但其内部按消息或 part 的装填顺序未在原笔记逐行核对（`public/script.js:4442-5257`；`public/scripts/openai.js:1533-1615`）。

正则的排序、同一消息上多个脚本的冲突合成规则，以及宏替换中的变量缺失、循环替换或脚本错误收口，均未由原笔记确认。生成拦截器的 manifest 顺序是本次已确认的唯一跨拦截器排序规则。

## 3. 请求层编译与模型可见结果

对 text completion API，系统提示先经 `substituteParams(system, {original: ...})` 或 `baseChatReplace` 处理；随后 story string、examples、聊天与最后一行组合为 `finalPrompt`。jailbreak 在继续生成时有插入到倒数第二条之前的特例。`getCombinedPrompt` 之前和之后的生成事件均允许扩展参与，后者可以整体替换结果，因此 `finalPrompt` 及其紧邻的 `generate_data.prompt` 才是该路径的请求层依据（`public/script.js:4627-4706, 5073-5257`）。

对 OpenAI API，消息在 `setOpenAIMessages()` 中转换，已确认其处理 narrator 到 system、名称前缀策略、媒体、工具调用和 reasoning 签名；之后由 `prepareOpenAIMessages()` 准备请求数据。它与 text completion 使用不同的拼装与截断实现，不能用前者的字符串顺序推断后者的最终消息数组（`public/scripts/openai.js:561-640, 1533-1615`）。

记忆、作者注释及向量检索结果通过扩展 prompt 槽参与合并。原笔记确认的槽位包括 `1_memory`、`2_floating_prompt`、`3_vectors` 和 `4_vectors_data_bank`；扩展自身如何产生这些内容不在本专题的已确认范围（`public/script.js:5285-5291`）。

## 4. 消息生命周期变换与交接

正则是已确认会跨越请求层与权威消息层的对象。构造上下文时，历史消息以 `isPrompt: true` 执行适用于其类型的正则，因此 `promptOnly` 脚本只改变模型可见的组装结果。无标记脚本除在 prompt 组装时生效外，还会由 `cleanUpMessage` 在生成后清洗回复；清洗结果写回 `chat[].mes` 并持久化。它因此会影响后续历史，而不仅是一次请求（`public/script.js:4442-4498, 6383-6534`；`public/scripts/extensions/regex/engine.js:334-381`）。

用户消息也在入 `chat` 前先执行正则、再做宏替换。这是消息创建路径的变换，不应与生成时对筛选后历史所做的 prompt 正则混为同一阶段（`public/script.js:5815-5864`）。回复的保存分支、JSONL 写回、恢复和分支语义不在本笔记范围。

World Info、角色字段、system/jailbreak、story string、chat inject 与扩展 prompt 在原笔记中被确认作为本次上下文的组装输入；没有证据表明它们借由该路径改写既有 `chat[]` 权威历史。该结论只限于已读生成和注入入口，不涵盖其各自扩展或编辑器的其他写入路径。

## 5. 显示层投影与消息渲染器交接

`markdownOnly` 正则只在 `messageFormatting` 的 Markdown 格式化路径以 `isMarkdown` 生效，不参与 prompt 组装，也没有被原笔记定位为写回 `chat[].mes`。同一正则配置的其他标记具有不同去向，不能因共用对象就推断显示替换会进入模型输入或权威消息（`public/script.js:1809-1813`；`public/scripts/extensions/regex/engine.js:334-381`）。

首条问候语另有渲染时宏替换特例；其显示实现和对权威消息的具体关系留在消息渲染器专题。流式过程中 `cleanUpMessage` 也会更新内存消息和 DOM，但流式 DOM 更新、节流及渲染生命周期不在本笔记范围。

## 6. 调试、预览与可解释性

`power_user.console_log_prompts` 会打印最终 prompt。每次生成的完整 prompt 与分项 token 数还会以 itemized prompts 写入 IndexedDB，并可通过消息上的 Prompt 按钮查看；它们是已确认的请求编译观测面（`public/script.js:5271-5322`）。

这些记录能够展示最终合并结果及分项 token 信息，但原笔记没有确认它们是否逐条显示 World Info 命中依据、宏展开前后差异、正则命中明细、拦截器变更，或是否在所有 API 类型下等价于最终发送 payload。界面预览与实时请求快照的关系也未验证。

## 7. 失败、更新与已确认边界

生成拦截器可通过 `abort(true)` 结束当前生成，属于已确认的规则阶段短路。World Info 扫描还受 `world_info_budget` 与 `budget_cap` 控制；text completion 的上下文裁剪不可逆，被裁掉的历史不会在同次编译中回填（`public/scripts/extensions.js:2015-2040`；`public/scripts/world-info.js:4597`；`public/script.js:4814-5068`）。

原笔记没有覆盖正则解析或执行错误、宏变量缺失、循环替换、异步脚本错误、规则版本迁移，或编辑器更新后的兼容收口。也没有依据支持将普通固定 system prompt、一次性用户输入、附件展开、历史筛选或检索本身都归为本专题的规则对象；这里只记录它们被已确认规则和编译步骤消费或交接的位置。

## 8. 未验证事项

- 正则、World Info、角色 depth prompt、扩展 prompt 与生成拦截器的持久化位置、schema、版本、启停状态和导入导出语义。
- World Info 的关键词、概率、白名单、冷却、优先级和多条命中时的合成顺序。
- 正则脚本之间的排序与冲突规则，以及变量缺失、循环替换、解析错误和脚本异常的处理。
- 宏在各调用点的完整变量集合、展开顺序，以及首条问候语渲染特例的运行结果。
- OpenAI `ChatCompletion`/`populateChatCompletion` 的内部预算装填粒度和最终消息数组的逐项运行核对。
- itemized prompts、控制台输出和消息 Prompt 按钮在各 API 路径下与实际发送 payload 的一致性；其是否提供规则命中与展开差异 trace。
- 多个规则作用点同时命中时，尤其是正则、World Info、扩展事件与拦截器交互的实际运行行为。

## 9. 关键源码索引

- `public/script.js`：`Generate()`（4231-5542）；`substituteParams`（2922）；`sendMessageAsUser`（5815-5864）；`cleanUpMessage`（6383-6534）；`getMaxPromptTokens`（5922-5928）；显示格式化中的 Markdown 正则调用（1809-1813）。
- `public/scripts/extensions/regex/engine.js`：`regex_placement`（281-292）；`getRegexedString`（334-381）；`runRegexScript`（391-448）。
- `public/scripts/world-info.js`：`getWorldInfoPrompt`（892-915）；`checkWorldInfo`（4597）。
- `public/scripts/extensions.js`：`runGenerationInterceptors`（2015-2040）。
- `public/scripts/openai.js`：`setOpenAIMessages`（561-640）；`prepareOpenAIMessages`（1533-1615）。
- `public/scripts/extensions/quick-reply/index.js`：事件绑定与优先监听（257-321）。
