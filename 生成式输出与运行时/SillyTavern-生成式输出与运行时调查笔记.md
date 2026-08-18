# SillyTavern 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/SillyTavern/SillyTavern`
>
> 调查更新日期：2026-08-10
>
> 代码快照：`8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8`（分支：`release`）
>
> 调查方式：静态代码审查；关键词 grep（artifact/canvas/sandbox/iframe/webview/notebook/exec/interpreter 等）定位能力边界，通读渲染管线（script.js 消息格式化与流式处理器）、正则引擎、工具调用、宏引擎、变量、媒体附件与后端持久化相关文件
>
> 调查范围：模型输出获得对象身份、专用表面、运行环境、编辑与持久化的整条链路；含工具调用结果物化、正则后处理、宏与变量、推理（reasoning）块、媒体附件、聊天持久化与回流。明确排除：Chat 类目的上下文装配与发送语义、消息渲染器的普通 Markdown 细节、Agent 工具类的注册与调度细节、World Info 的录入机制
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

SillyTavern 的输出模型非常单一：**模型输出只有"聊天气泡文本"一种对象形态**。聊天消息对象（ChatMessage）是唯一的事实源，`extra` 是开放元数据袋；展示上以 Markdown（showdown）+ DOMPurify 白名单净化为主，代码块仅有 highlight.js 高亮与复制按钮。本次未找到 artifact、canvas、notebook、sandbox、iframe/WebView 等任何输出运行环境，也未找到对模型文本的代码执行——全仓检索中 eval 与 `new Function` 只出现在注释和普通函数声明里。

能力分布：**G0（Markdown 聊天文本）为绝对主体**；**G1** 通过消息附带的媒体对象（`extra.media`，图片/视频可查看、下载、随聊天持久化）与记忆摘要等持久文本对象实现；**G2 部分**：OpenAI 兼容 function calling 让模型调用宿主注册的 JS 工具（`tool-calling.js` ToolManager），结果以系统消息物化并回注上下文，但没有 UI schema/声明式组件；正则扩展允许在展示与提示两侧重写文本（可注入受限 HTML，经净化）。**G3 及以上未找到**：无代码执行、无项目工作区、无桌面活对象。模型无法查询"对象列表"，只能通过聊天文本、工具注册表与变量间接感知状态；消息本身不可被模型定向寻址（无 UUID，仅有数组下标），工具的 id 由 API 返回。

## 系统边界与总体调用链

边界：Node 服务（`src/endpoints`）只负责文件读写与 API 代理，不执行任何模型产出代码；全部展示、后处理、交互在浏览器前端（`public/script.js` + `public/scripts/`）完成。输入侧对象（World Info、记忆、角色卡）由用户维护，仅经提示装配回流模型，不属于本类目。

**主链路（触发 -> 生成 -> 展示 -> 保存 -> 重新打开）**：

1. 用户发送：发送入口 `sendTextareaMessage`（script.js:1705）触发生成流程，聊天历史先经正则处理与文件内容组装（script.js:4442-4470）。
2. 请求发出后分两支：
   - 流式：专用流式处理器（script.js:3481）逐 token 循环累积，每个批次先经清洗（stopping string 截断、AI_OUTPUT 正则、Markdown 修正，script.js:6383）再整段重渲染消息正文（script.js:1753）；流中自动补齐未闭合的粗体、引号和代码围栏（script.js:3608）。
   - 非流式：响应经同一清洗流程后由 `saveReply` 收口（script.js:6583）。
3. 保存回复时构造消息对象（正文、`extra`、swipes 与各自版本信息，script.js:6682-6750），经渲染管线（script.js:2492 起）最终以 Markdown 转 HTML 加净化后写入消息 DOM（script.js:2464）。
4. 落盘：条件保存入口（script.js:9352）触发完整保存（script.js:7336），经服务端 `/api/chats/save` 以 JSONL 原子写入，带完整性校验与节流备份（chats.js:29-77）。
5. 重新打开：重载入口（script.js:1683）读取 JSONL 后逐条重渲染，源文本、`extra` 元数据（推理、媒体、工具调用等）与 swipes 全部恢复。

**第二闭环（工具调用）**：响应带 `tool_calls` 时由工具管理器执行函数（tool-calling.js:774），结果以系统消息 + `extra.tool_invocations` 物化并递归触发新一轮生成（script.js:5498-5499），下一轮提示构建再将其转回 function message（openai.js:612-635）；递归上限为 5 轮（tool-calling.js:255）。

**第三闭环（持久文本对象）**：记忆扩展以静默生成方式产出摘要文本，写入 `extension_settings.memory` 并随 settings.json 持久化，之后每次提示经 `{{summary}}` 模板重新注入（extensions/memory/index.js:701、751）。

## 1. 触发方式、输出协议与对象模型

- **触发**：无"输出协议"。模型自由文本是唯一内容通道，另有 OpenAI 兼容的 `tool_calls` 结构化通道（`ToolManager.parseToolCalls`，tool-calling.js:427），支持 OpenAI、Claude、Cohere、Gemini 各自的增量事件格式。模型返回的图片经提取函数（script.js:6144）从 Gemini/OpenRouter 响应中转为 data URL。
- **半截流处理**：流式阶段依赖文本启发式——stopping string 尾部匹配截断（script.js:6410-6419）、引用平衡（script.js:3608-3614）、`displayIncompleteSentences` 控制（script.js:3604）；tool call 参数走 JSON delta 拼接（tool-calling.js:508-533），失败则告警并丢弃。
- **对象模型**：唯一输出对象是聊天消息（ChatMessage），身份为 `chat` 数组下标，DOM 上以 `mesid` 属性表示（script.js:2588-2599）；无 UUID、无版本号、无类型声明。`extra` 是开放元数据袋，承载模型信息、推理、token 计数、翻译投影、工具调用、媒体、书签、生成 ID 等可选字段，无固定 schema。事实源是内存 `chat` 数组 → JSONL 文件；运行实例（DOM）每次从对象重新渲染，DOM 不是事实源。`extra` 实际出现的字段集合如下（代码块，逐字保留）：
  ```
  api/model、reasoning、reasoning_signature、reasoning_duration、token_count、
  time_to_first_token、display_text（翻译投影）、tool_invocations、media（数组）、
  media_display/media_index、bias、type（narrator 等）、isSmallSys、uses_system_ui、
  bookmark_link、gen_id、append_title
  ```
- **误触发防护**：正则脚本是文本后处理的唯一协议，通过放置位置（用户输入、模型输出、斜杠命令、World Info、推理等，engine.js:281）与 markdownOnly/promptOnly 及深度区间过滤控制触发面（engine.js:347-377），无嵌套解析，替换串支持 `{{match}}`/`$1` 宏化（engine.js:419-445）。

## 2. 增量生成、更新与最终化

- **更新粒度**：整段重渲。每个流式批次都把当前累积文本经清洗与格式化后整段写入消息 DOM（script.js:3656-3671），`stream_fade_in` 时用平滑替换动画。没有按 AST/节点 patch，没有 diff。宏在流式阶段不展开——模型输出默认不跑参数替换，仅首条消息例外（script.js:1758-1765）。
- **最终化**：收口入口（script.js:3696）依次完成代码块复制按钮、推理收尾、swipe 同步、图片附件处理（script.js:3724-3727），随后广播消息接收与渲染事件（script.js:3740-3741）并触发条件保存（script.js:3756）。
- **失败收口**：失败处理入口（script.js:3761）中止后仍广播渲染事件；文本完成但被过滤时自动切换 swipe（script.js:3753）；工具调用失败以错误标记的 invocation 回注，让模型看到失败（tool-calling.js:805-821）。

## 3. 投影表面与多视图关系

- **消息正文**（`.mes_text`）：主表面，投影源选择由 `extra.display_text` 优先于 `mes` 决定（script.js:2469-2470）。翻译扩展写入 `extra.display_text`（extensions/translate/index.js:215）构成"源文本 ↔ 显示投影"双视图，源始终是 `mes`。
- **推理块**：reasoning 存 `extra.reasoning`，折叠式展示，可单独编辑（reasoning.js:542、930）。
- **媒体栏**：`extra.media` 数组（每条记录含 URL、类型、标题、来源与生成类型）渲染为消息内媒体块，含画廊布局与播放（script.js:2636）；DOM 媒体状态在重渲时保存/恢复（script.js:2413-2416）。
- **浮动面板**：`StreamingDisplay`（streaming-display.js:35）是独立于聊天的悬浮面板，用于 Connection Manager 的 `/generate` 类命令与新版 API 流式显示，可最小化/关闭/停止。
- 无侧栏对象区、无画布、无独立窗口（Electron 仅作启动器）。同一消息对象只有正文+媒体+推理三个同步投影，无多源投影。

## 4. 表现类型、依赖与运行环境

- **支持的层级**：
  - Markdown：showdown 渲染，处理器重载点 script.js:521，扩展点 `markdownUnderscoreExt`/`markdownExclusionExt`；
  - 代码高亮：highlight.js；
  - 受限 HTML：DOMPurify 净化。
- **净化边界**（chats.js:1901 `addDOMPurifyHooks` + script.js:1898-1909）：消息净化开启 `MESSAGE_SANITIZE`，按下列规则执行，模型输出可以注入受限 CSS 但被限定在消息内：
  - 样式：`ADD_TAGS` 允许 `custom-style` 标签；`<style>` 被编码再解码为作用域前缀 `.mes_text `（chats.js:536、551）；未知类名加 `custom-` 前缀，`fa-`/`note-`/`monospace` 保留；
  - 链接：强制添加 `target=_blank` 与 noopener；
  - 外部媒体：AUDIO/VIDEO/IMG/EMBED 等默认经 `isExternalMediaAllowed` 拦截（chats.js:852，受 `forbid_external_media` 控制）；
  - 系统 UI：`menu_button` 类仅在 `MESSAGE_ALLOW_SYSTEM_UI` 时放行，该开关只对应用自身消息生效（`extra.uses_system_ui`，system-messages.js:68-95 的欢迎页/提示模板）。
- **运行环境**：无 iframe/WebView/worker/沙箱运行模型产出。代码块只是高亮文本。HTML/JS 不执行（无 eval、无 `new Function` 作用于模型文本）。
- 本次未找到 KaTeX/MathJax/Mermaid 等图表渲染（全仓 grep 无命中）；数学相关仅 `\begin{align*}` → `$$` 的文本替换（script.js:1878-1879）。

## 5. 用户交互、事件与错误反馈

- **消息级交互**（均为宿主固定按钮，非模型声明组件）：swipe 换版、编辑、删除、复制代码、书签、头像点击、按消息生成 SD 图、逐条提示查看、生成计时提示、推理编辑与范围隐藏/删除等，主入口见 script.js:2420-2437，扩展动作见 stable-diffusion/index.js:5039、chats.js:147。
- **事件回传**：`eventSource` 事件总线（events.js:4-110）是扩展观察与介入输出的唯一通道，覆盖消息接收/渲染/编辑、工具调用、流式 token 等生命周期事件；`runGenerationInterceptors`（extensions.js:2015）允许扩展在生成前改写提示。quick-reply 扩展按事件自动执行用户预设命令链（extensions/quick-reply/src/AutoExecuteHandler.js:48-102）。
- **错误反馈**：工具错误、生成错误以 toast 与详情弹窗呈现（tool-calling.js:916-921、script.js:5412-5418）；正则调试器提供 diff 视图与逐步回放（regex/index.js:942-1048）。
- **重载恢复**：交互状态（swipe 位置、播放中媒体）随消息对象/`saveMediaStates` 恢复；`mesid`、`swipeid` 属性落回 DOM（script.js:2588-2599）。未运行验证。

## 6. 编辑、diff、版本与协作

- **编辑**：全文覆盖式。编辑保存入口（script.js:8080-8134）按 placement 重跑正则（仅 `isEdit` 标记的 `runOnEdit` 脚本，engine.js:356）、展开宏、同步回当前 swipe 并记录 `extra.bias`；推理单独可编辑（reasoning.js:930）。
- **版本**：swipes 是唯一版本机制——同一消息的多条候选文本 + 各自 `swipe_info`（发送/生成起止时间与 `extra` 深拷贝），可删除单条（`MESSAGE_SWIPE_DELETED`）。无 diff、无 patch、无接受/拒绝、无分支合并；"继续"是纯文本追加（script.js:6638-6681）。
- **协作**：单用户本地应用，无协作。正则编辑器提供预览式 diff 视图仅用于调试（regex/index.js:962 `highlightedOutput`），不改写消息历史。

## 7. 能力桥、执行位置与权限范围

- **执行位置**：全部在浏览器主线程 DOM；服务端无执行面（`src/endpoints` 全部是文件/API 代理）。工具动作是宿主注册的普通 JS 函数（tool-calling.js:269），在浏览器上下文内执行；`/tools-register` 允许把 slash 命令注册为工具动作（tool-calling.js:988-1137），仍属于宿主预编译代码，模型不提供可执行文本。
- **网络/媒体授权**：模型返回的外部媒体默认被拦（见 §4）；用户上传与 SD 生成走 `/api/media` 等自有端点。无模型直接发起的任意网络访问。
- **存储/模型调用桥**：扩展可读写设置（`extension_settings`）、读写角色卡字段（extensions.js:2061）、发起静默或原始模型调用；例如表达式分类扩展用 LLM/BERT 对消息文本分类以驱动角色立绘切换（extensions/expressions/index.js:1041-1152）。
- 无逐项授权/审批 UI（工具自动执行，仅开关 `function_calling` 与递归上限）。

## 8. 持久化、恢复、分享与导出

- **格式**：聊天为 JSONL（首行 `chat_metadata` 头，script.js:7368-7373）；设置（含 `extension_settings`：正则脚本、全局变量、记忆、QR 配置）为 settings.json；世界信息为独立 JSON 文件（用户输入侧）。保存走原子写入 + 节流备份 + `chat_metadata.integrity` 完整性校验，校验失败需输入 `OVERWRITE` 才强制覆盖（script.js:7394-7416；chats.js:29-77、311-325）。
- **恢复**：按 `character/chat` 文件名读取；`extra` 全部随 JSONL 往返。`display_text` 等投影不入库（翻译后重新生成，translate/index.js:628-684 负责删除以重建）。
- **分享/导出**：聊天导出 txt/html（script.js:11440-11482 → `/api/chats/export`，chats.js:604）；导入支持 ooba、Agnai、CAI、KoboldLite、Chub、Risu 等外部格式（chats.js:110-309）；正则脚本可导出单文件 JSON（regex/index.js:700-704）；角色卡导出时扩展字段随卡迁移（extensions.js:2061 相关，属插件类目边界）。
- **删除/迁移**：聊天、角色卡、世界信息均有删除与迁移入口（chats.js、world-info.js:5881 `moveWorldInfoEntry`），数据 maid 可批量清理聊天文件（data-maid.js）。

## 9. 模型回流、对象感知与持续维护

- **提示重建**：每次生成都从消息对象重建提示（openai.js:561）：正文、推理（script.js:4480-4494）、媒体标题（script.js:4450-4463）、文件附件内容（script.js:4448）、工具调用转 function message（openai.js:612-635）；推理签名仅在同 API/模型时回传（openai.js:614-621）。正则同时在提示侧与展示侧各跑一遍，同一源产生两份文本。
- **持续维护的文本对象**：
  - 记忆摘要：`extension_settings.memory`，经 `{{summary}}` 模板注入；
  - 变量：`{{setvar}}`/`{{getvar}}` 宏，全局变量在 settings、会话级在 `chat_metadata.variables`（variables.js:23-77）；
  - World Info：激活随每轮扫描（world-info.js:4597，输入侧）。
- **对象寻址**：模型**不能**查询对象列表或定向修改某个输出对象。工具调用是唯一的"命名操作"通道（工具名 + JSON 参数），但工具的持久状态由宿主函数自行管理，框架不提供对象句柄；聊天消息只有下标身份，swipe 文本对模型只是历史文本。记忆摘要更新是"整段覆盖旧摘要"式的文本替换，无版本。
- 结论：无 G5 意义上的对象感知与定向维护；闭环仅存在于"文本进文本出 + 工具结果文本回流"。

## 10. 生命周期、资源治理与性能

- 不可见消息不冻结（DOM 全量渲染后即静态化）；媒体播放状态在重渲时保存恢复（script.js:2413-2416）；外部媒体被拦截时暂停 autoplay（chats.js:2025-2028）。
- 定时器/动画：悬浮面板的隐藏与自动隐藏定时器在 hide 时清理（streaming-display.js:381-429）；流式渲染按用户配置的帧率节流（`power_user.streaming_fps`，script.js:3814）；中止走 `AbortController`（script.js:3508、3788-3791）。
- 长会话/多对象限额：
  - World Info 预算百分比与上限（world-info.js:4624-4629）；
  - 工具递归上限 5（tool-calling.js:255）；
  - 正则编译缓存 LRU 1000（engine.js:40-82）与 `depth` 深度过滤（engine.js:362-372）。
  无对象级暂停/冻结策略，因为不存在常驻输出对象。

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
