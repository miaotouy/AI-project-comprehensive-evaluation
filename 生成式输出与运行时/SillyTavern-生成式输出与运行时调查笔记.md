# SillyTavern 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/SillyTavern/SillyTavern`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`06bde939fb1e9c4c8d8641d810f0a916b5bce127`（分支：`release`）
>
> 调查方式：静态代码审查；关键词 grep（artifact/canvas/sandbox/iframe/webview/notebook/exec/interpreter 等）定位能力边界，通读渲染管线（script.js 消息格式化与流式处理器）、正则引擎、工具调用、宏引擎、变量、媒体附件与后端持久化相关文件
>
> 调查范围：模型输出获得对象身份、专用表面、运行环境、编辑与持久化的整条链路；含工具调用结果物化、正则后处理、宏与变量、推理（reasoning）块、媒体附件、聊天持久化与回流。明确排除：Chat 类目的上下文装配与发送语义、消息渲染器的普通 Markdown 细节、Agent 工具类的注册与调度细节、World Info 的录入机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

SillyTavern 的输出模型单一：**模型输出只有"聊天气泡文本"一种对象形态**。聊天消息对象（ChatMessage）是唯一的事实源，`extra` 是开放元数据袋；展示上以 Markdown（showdown）+ DOMPurify 白名单净化为主，代码块仅有 highlight.js 高亮与复制按钮。本次未找到 artifact、canvas、notebook、sandbox、iframe/WebView 等任何输出运行环境，也未找到对模型文本的代码执行——全仓检索中 eval 与 `new Function` 只出现在注释和普通函数声明里。

能力分布：**G0（Markdown 聊天文本）为绝对主体**；**G1** 通过消息附带的媒体对象（`extra.media`，图片/视频可查看、下载、随聊天持久化）与记忆摘要等持久文本对象实现；**G2 部分**：OpenAI 兼容 function calling 让模型调用宿主注册的 JS 工具（`tool-calling.js` ToolManager），结果以系统消息物化并回注上下文，但没有 UI schema/声明式组件；正则扩展允许在展示与提示两侧重写文本（可注入受限 HTML，经净化）。**G3 及以上未找到**：无代码执行、无项目工作区、无桌面活对象。模型无法查询"对象列表"，只能通过聊天文本、工具注册表与变量间接感知状态；消息本身不可被模型定向寻址（无 UUID，仅有数组下标），工具的 id 由 API 返回。

## 系统边界与总体调用链

边界：Node 服务（`src/endpoints`）只负责文件读写与 API 代理，不执行任何模型产出代码；全部展示、后处理、交互在浏览器前端（`public/script.js` + `public/scripts/`）完成。输入侧对象（World Info、记忆、角色卡）由用户维护，仅经提示装配回流模型，不属于本类目。

**主链路（触发 -> 生成 -> 展示 -> 保存 -> 重新打开）**：

1. 用户发送：`sendTextareaMessage` 接收输入并触发生成流程，聊天历史先经正则处理，再与文件内容一起组装成提示（script.js:1705、4442-4470）。
2. 请求发出后分两支：
   - 流式：专用流式处理器逐 token 累积，每个批次先做清洗（stopping string 截断、AI_OUTPUT 正则、Markdown 修正）再整段重渲染消息正文，流中自动补齐未闭合的粗体、引号和代码围栏（script.js:3481、6383、1753、3608）。
   - 非流式：响应走同一清洗流程，最后由 `saveReply` 收口（script.js:6583）。
3. 保存回复时构造消息对象，写入正文、`extra` 与各 swipes 的版本信息，再经渲染管线把 Markdown 转成 HTML、净化后写进消息 DOM（script.js:6682-6750、2492、2464）。
4. 落盘：条件保存入口触发完整保存，经服务端 `/api/chats/save` 以 JSONL 原子写入，带完整性校验与节流备份（script.js:9352、7336；chats.js:29-77）。
5. 重新打开：重载入口读取 JSONL 后逐条重渲染，源文本、`extra` 里的推理、媒体与工具调用元数据、以及 swipes 一并恢复（script.js:1683）。

**第二闭环（工具调用）**：模型响应带 `tool_calls` 时，工具管理器调用宿主注册的函数，把结果写成一条系统消息并记录到 `extra.tool_invocations`，随即递归触发新一轮生成；下一轮构建提示时再把这些记录转成 function message 回传给模型。递归最多 5 轮（tool-calling.js:774、255；script.js:5498-5499；openai.js:612-635）。

**第三闭环（持久文本对象）**：记忆扩展以静默生成方式产出摘要文本，写入 `extension_settings.memory` 并随 settings.json 持久化，之后每次提示经 `{{summary}}` 模板重新注入（extensions/memory/index.js:701、751）。

## 1. 触发方式、输出协议与对象模型

- **触发**：模型输出的常规通道是自由文本，宿主未定义专门的输出协议；另有一条 OpenAI 兼容的 `tool_calls` 结构化通道，解析入口 `ToolManager.parseToolCalls` 按 OpenAI、Claude、Cohere、Gemini 各自的增量事件格式处理（tool-calling.js:427）。模型返回的图片由提取函数从 Gemini、OpenRouter 的响应中转成 data URL（script.js:6144）。
- **半截流处理**：流式阶段靠文本启发式判断内容是否完整：尾部命中 stopping string 就截断，引号与代码围栏按平衡状态处理，`displayIncompleteSentences` 决定半句是否照常显示。工具调用参数按 JSON delta 逐片拼接，拼接失败时告警并丢弃该次调用（script.js:6410-6419、3608-3614、3604；tool-calling.js:508-533）。
- **对象模型**：唯一的输出对象是聊天消息，身份由 `chat` 数组下标确定，展示时体现为 DOM 上的 `mesid` 属性；消息没有 UUID、版本号和类型声明（script.js:2588-2599）。每条消息的 `extra` 是开放元数据袋，承载模型信息、推理、token 计数、翻译投影、工具调用、媒体、书签、生成 ID 等可选字段，没有固定 schema。内存中的 `chat` 数组是事实源，JSONL 文件保存它的副本，DOM 每次从对象重新渲染、只作为运行实例。`extra` 实际出现的字段集合如下：
  ```
  api/model、reasoning、reasoning_signature、reasoning_duration、token_count、
  time_to_first_token、display_text（翻译投影）、tool_invocations、media（数组）、
  media_display/media_index、bias、type（narrator 等）、isSmallSys、uses_system_ui、
  bookmark_link、gen_id、append_title
  ```
- **误触发防护**：正则脚本是文本后处理的唯一协议，通过放置位置（用户输入、模型输出、斜杠命令、World Info、推理等，engine.js:281）与 markdownOnly/promptOnly 及深度区间过滤控制触发面（engine.js:347-377），无嵌套解析，替换串支持 `{{match}}`/`$1` 宏化（engine.js:419-445）。

## 2. 增量生成、更新与最终化

- **更新粒度**：整段重渲。每个流式批次都把当前累积文本清洗、格式化后整段写回消息 DOM，`stream_fade_in` 开启时用平滑替换动画过渡；更新以整段替换进行，不涉及 AST、节点级 patch 或 diff。宏在流式阶段不展开，模型输出默认不做参数替换，仅首条消息例外（script.js:3656-3671、1758-1765）。
- **最终化**：流式结束后由收口入口依次补上代码块复制按钮、收尾推理块、同步 swipe、处理图片附件，然后广播消息接收与渲染事件并触发条件保存（script.js:3696、3724-3727、3740-3741、3756）。
- **失败收口**：失败处理入口中止生成后仍广播渲染事件；若文本已生成但整段被过滤，宿主自动切到下一条 swipe；工具调用失败时，错误标记写进 invocation 再回注上下文，模型能看到这次失败（script.js:3761、3753；tool-calling.js:805-821）。

## 3. 投影表面与多视图关系

- **消息正文**（`.mes_text`）：这是主表面。渲染时优先取 `extra.display_text`，该字段为空才回落到 `mes`；翻译扩展把译文写进 `extra.display_text`，同一条消息因此形成源文本与显示投影两份视图，源文本始终保留在 `mes` 中（script.js:2469-2470；extensions/translate/index.js:215）。
- **推理块**：推理内容存在 `extra.reasoning`，折叠展示，并与正文分开单独编辑（reasoning.js:542、930）。
- **媒体栏**：`extra.media` 数组渲染成消息内的媒体块，支持画廊布局与播放；每条记录带 URL、类型、标题、来源和生成类型，DOM 中的播放状态在重渲时保存并恢复（script.js:2636、2413-2416）。
- **浮动面板**：`StreamingDisplay` 提供一块独立于聊天区的悬浮面板，用于 Connection Manager 的 `/generate` 类命令和新版 API 的流式显示，可最小化、关闭与停止（streaming-display.js:35）。
- 界面没有侧栏对象区、画布或独立窗口，Electron 只承担启动器角色；同一消息对象只投射出正文、媒体与推理三个同步表面，没有多源投影。

## 4. 表现类型、依赖与运行环境

- **支持的层级**：展示层由 Markdown 渲染、代码高亮与 HTML 净化三层叠加而成。
  - Markdown 渲染交给 showdown，处理器在 script.js:521 处重载，另可挂 `markdownUnderscoreExt` 与 `markdownExclusionExt` 两个扩展点；
  - 代码高亮交给 highlight.js；
  - 原始 HTML 经 DOMPurify 净化后进入 DOM。
- **净化边界**：消息净化在 `MESSAGE_SANITIZE` 开启后生效，由 DOMPurify 钩子按下列规则执行，模型输出可以向消息内注入受限 CSS，作用范围限定在消息内（钩子注册见 chats.js:1901，调用点见 script.js:1898-1909）：
  - 样式：`ADD_TAGS` 放行 `custom-style` 标签；`<style>` 内容先编码、解码后加上 `.mes_text ` 作用域前缀；未知类名统一加 `custom-` 前缀，`fa-`、`note-`、`monospace` 保留原样（chats.js:536、551）；
  - 链接：强制补上 `target=_blank` 与 noopener；
  - 外部媒体：AUDIO、VIDEO、IMG、EMBED 等外部媒体默认由 `isExternalMediaAllowed` 判定拦截，开关为 `forbid_external_media`（chats.js:852）；
  - 系统 UI：`menu_button` 类只在 `MESSAGE_ALLOW_SYSTEM_UI` 开启时放行，该开关仅对应用自身发出的消息生效（`extra.uses_system_ui`，覆盖欢迎页与提示模板，system-messages.js:68-95）。
- **运行环境**：模型产出由宿主消息渲染层承载，代码围栏按高亮文本显示；正文中的 HTML 则经过净化后以受限标记进入消息 DOM（[Markdown 转换与净化](<../../SillyTavern/public/script.js#L1933-L1968>)、[正文插入](<../../SillyTavern/public/script.js#L2695-L2697>)）。这条链没有独立的 iframe、WebView、worker 或沙箱来运行模型代码，模型文本也不经过 eval 或 `new Function`。
- 本次未找到 KaTeX、MathJax 或 Mermaid 等图表渲染（全仓 grep 无命中）；与数学相关的处理只有把 `\begin{align*}` 替换成 `$$` 的文本替换（script.js:1878-1879）。

## 5. 用户交互、事件与错误反馈

- **消息级交互**：宿主为每条消息固定挂载一批按钮，模型无法声明自定义组件。
  - 消息操作：swipe 换版、编辑、删除、复制代码、书签；
  - 生成与查看：头像点击、按消息生成 SD 图、逐条提示查看、生成计时提示、推理编辑与范围隐藏/删除。
  主入口在 script.js:2420-2437，扩展动作见 stable-diffusion/index.js:5039、chats.js:147。
- **事件回传**：`eventSource` 事件总线是扩展观察和介入输出的主要通道，覆盖消息接收、渲染、编辑、工具调用与流式 token 等生命周期事件（events.js:4-110）。扩展还能通过 `runGenerationInterceptors` 在生成前改写提示（extensions.js:2015），或在正文进入 DOM 前用 `MessageFormatter` 钩子同步改写文本，改写时机可选在正则前后或 Markdown 转 HTML 之后（渲染细节见消息渲染器笔记）。quick-reply 扩展则按事件自动执行用户预设的命令链（extensions/quick-reply/src/AutoExecuteHandler.js:48-102）。
- **错误反馈**：工具调用错误和生成错误先以 toast 提示，再提供详情弹窗；正则调试器另有 diff 视图与逐步回放（tool-calling.js:916-921、script.js:5412-5418；regex/index.js:942-1048）。
- **重载恢复**：页面重开后，swipe 位置与播放中的媒体由消息对象及 `saveMediaStates` 一并恢复，`mesid`、`swipeid` 属性重新写回 DOM（script.js:2588-2599）。未运行验证。

## 6. 编辑、diff、版本与协作

- **编辑**：保存时以编辑后的全文覆盖原消息。保存入口按 placement 重跑正则，只执行带 `isEdit` 标记的 `runOnEdit` 脚本，随后展开宏、把结果同步回当前 swipe 并记录 `extra.bias`；推理内容走单独的编辑入口（script.js:8080-8134；engine.js:356；reasoning.js:930）。
- **版本**：swipes 是唯一的版本机制：同一消息可保存多条候选文本，每条带自己的 `swipe_info`，记录发送与生成起止时间以及一份 `extra` 深拷贝，单条可删除（删除事件为 `MESSAGE_SWIPE_DELETED`）。版本之间没有 diff、patch、接受/拒绝和分支合并操作；"继续"只是在末尾追加文本（script.js:6638-6681）。
- **协作**：应用面向单用户本地使用，没有协作功能。正则编辑器的预览式 diff 视图只用于调试高亮输出，修改停留在预览里，消息历史保持原样（regex/index.js:962 `highlightedOutput`）。

## 7. 能力桥、执行位置与权限范围

- **执行位置**：所有动作都在浏览器主线程中完成，服务端没有执行面，`src/endpoints` 下的端点全部是文件读写与 API 代理。工具动作是宿主注册的普通 JS 函数，在浏览器上下文里执行，`/tools-register` 还能把 slash 命令注册成工具动作；这些代码都由宿主预先提供，模型只提交调用名与 JSON 参数（tool-calling.js:269、988-1137）。
- **网络/媒体授权**：模型返回的外部媒体默认被拦截（规则见 §4）；用户上传与 SD 生成的媒体走 `/api/media` 等自有端点。模型自身没有发起任意网络访问的通路。
- **存储/模型调用桥**：扩展能读写 `extension_settings` 里的设置、读写角色卡字段，也能发起静默调用或原始模型调用；表达式分类扩展即用 LLM 或 BERT 对消息文本分类，据此切换角色立绘（extensions.js:2061；extensions/expressions/index.js:1041-1152）。
- 工具调用没有逐项授权或审批界面，是否执行由 `function_calling` 开关和递归上限两个条件约束。

## 8. 持久化、恢复、分享与导出

- **格式**：聊天存成 JSONL，首行是 `chat_metadata` 头；设置存成 settings.json，其中 `extension_settings` 容纳正则脚本、全局变量、记忆与 QR 配置；世界信息是独立的 JSON 文件，属于用户输入侧。保存时先原子写入、再做节流备份，并用 `chat_metadata.integrity` 校验完整性，校验不通过时必须输入 `OVERWRITE` 才能强制覆盖（script.js:7368-7373、7394-7416；chats.js:29-77、311-325）。
- **恢复**：按 `character/chat` 形式的文件名读取，`extra` 随 JSONL 完整往返。翻译投影 `display_text` 等字段不写入文件，重新翻译时由 translate/index.js:628-684 先删除再重建。
- **分享/导出**：聊天可导出为 txt 或 html，入口在 script.js:11440-11482，服务端由 `/api/chats/export` 承接（chats.js:604）；导入支持 ooba、Agnai、CAI、KoboldLite、Chub、Risu 等外部格式（chats.js:110-309）；正则脚本可单独导出为 JSON 文件（regex/index.js:700-704）；角色卡导出时扩展字段随卡迁移（extensions.js:2061 相关，属插件类目边界）。
- **删除/迁移**：聊天、角色卡与世界信息都提供删除和迁移入口，世界信息的迁移由 `moveWorldInfoEntry` 负责；数据 maid 可以批量清理聊天文件（chats.js、world-info.js:5881、data-maid.js）。

## 9. 模型回流、对象感知与持续维护

- **提示重建**：每轮生成都从消息对象重新拼出提示，正文、推理、媒体标题与文件附件内容依次进入不同片段，工具调用记录再转成 function message 追加（script.js:4448、4450-4463、4480-4494；openai.js:612-635）。推理签名只在同 API、同模型时回传（openai.js:561、614-621）。正则同时在提示侧和展示侧各跑一遍，同一份源文本因此产生两份结果。
- **持续维护的文本对象**：
  - 记忆摘要存放在 `extension_settings.memory`，之后每次提示经 `{{summary}}` 模板注入；
  - 变量由 `setvar`、`getvar` 系列宏读写，全局变量保存在 settings，会话变量落在 `chat_metadata.variables`；另一组 `setvarkey`、`getvarkey` 宏按 key 或下标访问对象与数组元素（variables.js:23-77；`public/scripts/macros/definitions/variable-macros.js:158-214,361-417`）；
  - World Info 的激活状态随每轮扫描更新，属于输入侧（world-info.js:4597）。
- **对象寻址**：模型查不到对象列表，也无法定向修改某个输出对象。工具调用是唯一的"命名操作"通道，调用时只带工具名与 JSON 参数；工具的持久状态由宿主函数自行管理，框架不向模型提供对象句柄。聊天消息对模型只有下标身份，swipe 里的候选文本也只是历史文本。记忆摘要的更新方式是整段覆盖旧摘要，没有版本。
- 结论：这套实现不具备 G5 意义上的对象感知与定向维护能力，闭环只发生在"文本进、文本出，工具结果以文本回流"这条链上。

## 10. 生命周期、资源治理与性能

- 不可见的消息不做冻结，DOM 全量渲染完成后状态不再变化；媒体播放状态在重渲时保存并恢复，外部媒体被拦截时自动暂停 autoplay（script.js:2413-2416；chats.js:2025-2028）。
- 定时器/动画：悬浮面板在隐藏或自动隐藏时清理自己的定时器，流式渲染按用户配置的帧率（`power_user.streaming_fps`）节流，中止生成走 `AbortController`（streaming-display.js:381-429；script.js:3814、3508、3788-3791）。
- 长会话/多对象限额：
  - World Info 的预算百分比与上限（world-info.js:4624-4629）；
  - 工具递归最多 5 轮（tool-calling.js:255）；
  - 正则编译缓存按 LRU 保留 1000 条，并用 `depth` 做深度过滤（engine.js:40-82、362-372）。
  输出对象不常驻，因此没有对象级的暂停或冻结策略。

## 11. 测试、已确认边界与未验证事项

- **测试现状**：`tests/` 为 Jest 单元（util、prompt-converters、schema 扁平化、角色卡校验、mock server、私有请求过滤）+ Playwright E2E（tests/frontend/Macro*.e2e.js 覆盖宏引擎词法/解析/注册/环境）。**未找到**针对正则引擎、工具调用、消息格式化/净化管线、流式渲染的测试（搜索范围：tests 全目录）。
- **已确认边界**（源码直接确认）：
  - 无 artifact/canvas 工作区/notebook/sandbox/webview 输出表面；"canvas"仅用于图片缩略图（utils.js:1257-1270、1902-1916），"sandbox/webview/notebook"全仓零命中（搜索范围：public/scripts、src 全部 js）。
  - 无模型文本代码执行；`eval`/`new Function` 命中均为注释或普通函数声明（world-info.js、tags.js、utils.js、tool-calling.js、macros.js 等抽查均如此）。
  - iframe 仅出现在 nanogallery 库与 data-maid 的注释中，data-maid 实际用 textarea 查看文本（data-maid.js:368-381）。
  - 无 KaTeX/MathJax/Mermaid；无 JSON Schema 驱动 UI；无 diff/patch 编辑器。
- **推断**（基于静态代码）：流式渲染性能与 `stream_fade_in` 视觉行为、外部媒体拦截的实际触发、工具递归的实际对话行为均属推断。
- **未验证事项**：未运行服务与浏览器，所有 DOM 行为（编辑弹窗、swipe 交互、媒体播放恢复、正则调试器 UI、StreamingDisplay 动画）未经运行验证；测试未执行。

## 12. 关键源码索引

- `public/script.js:521 reloadMarkdownProcessor`、`1753 messageFormatting`、`2464 getMessageTextHTML`、`2420 addCopyToCodeBlocks` —— 展示管线
- `public/script.js:3481 StreamingProcessor`、`3584 onProgressStreaming`、`3696 finalizeIntermediaryMessage`、`6383 cleanUpMessage` —— 流式生成与最终化
- `public/script.js:6583 saveReply`、`7336 saveChat`、`8080 updateMessage` —— 对象构造与持久化
- `public/scripts/chats.js:1901 addDOMPurifyHooks`、`536 encodeStyleTags`、`852 isExternalMediaAllowed` —— 净化与媒体边界
- `public/scripts/tool-calling.js:242 ToolManager`、`427 parseToolCalls`、`774 invokeFunctionTools`、`887 saveFunctionToolInvocations` —— 工具调用物化
- `public/scripts/openai.js:561 setOpenAIMessages`、`612` —— 工具/推理回注提示
- `public/scripts/extensions/regex/engine.js:334 getRegexedString`、`281 regex_placement` —— 文本后处理协议
- `public/scripts/extensions/memory/index.js:701`、`751` —— 摘要对象回流
- `public/scripts/extensions/stable-diffusion/index.js:4966 sendMessage` —— 媒体消息物化
- `public/script.js:6144 extractImagesFromData`、`6544 processImageAttachment` —— 模型返回媒体
- `public/scripts/streaming-display.js:35 StreamingDisplay` —— 悬浮投影
- `src/endpoints/chats.js:470`、`604` —— 保存与导出
- `public/scripts/events.js:4` —— 事件回传面
- `tests/frontend/Macro*.e2e.js` —— 宏引擎测试
