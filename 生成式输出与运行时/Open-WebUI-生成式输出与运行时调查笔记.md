# Open WebUI 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/open-webui/open-webui`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`d3e8bf3405e848cfba377814d0aa7ba7290e414d`（分支：`main`）
>
> 调查方式：静态代码阅读，grep/glob 覆盖前后端关键词（artifact、code interpreter、pyodide、jupyter、iframe、notebook、embeds、files、execute），沿“生成->物化->展示->执行->编辑->保存->回流”链路逐段核对；未运行构建、服务或任何执行流程
>
> 调查范围：模型输出对象（代码解释器、HTML/SVG Artifact、工具结果文件/嵌入、Pyodide 与终端文件系统、notebook）的对象模型、投影、执行环境、编辑与持久化、模型回流。排除：消息渲染器通用 Markdown/高亮/KaTeX/静态 Mermaid 细节、Agent 工具注册与调度语义、RAG 检索本身
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI 的生成式输出深度分布在一套“消息即事实源”的模型上：代码解释器输出是唯一具备完整“触发->执行->结果->展示->编辑->保存->重新打开->模型回流”生命周期的输出对象（Responses API 风格 `open_webui:code_interpreter` output item，持久化在 `ChatMessage.output` JSON 列）；HTML/CSS/JS Artifact 是消息正文代码块的派生投影（侧栏 iframe），无独立对象身份、不可编辑、不可回流；Pyodide 文件系统是浏览器沙箱内的会话级活文件系统（可跨会话持久化但默认关闭）；终端工作区（文件浏览、notebook、端口预览）全部委托给外部 Terminal 服务器。代码执行引擎三选一：浏览器 Pyodide（WASM worker 或隐藏 iframe 沙箱）、远端 Jupyter（REST+WebSocket）、外部终端服务器。能力等级判定：**G3 为主（可执行 Artifact + 会话内活对象），兼具 G4 的部分特征（代码块/notebook 单元编辑保存、文件编辑回写）与 G5 的会话级局部（模型可读写 `/mnt/uploads` 并就地更新同一输出项）**；无 diff/版本/接受拒绝、无跨会话对象保证、无多投影同步。

## 系统边界与总体调用链

两类主要输出链路：

1. **代码解释器链**（legacy function-calling 模式下由模型自由文本触发，XML 标签协议）：
   模型流式输出 `<code_interpreter>` 标签，`tag_output_handler` 切分消息并创建 `open_webui:code_interpreter` output item（逐 chunk 累积 code）；流结束后 `middleware.py:5325` 循环执行（最多 5 轮）：
   - pyodide 引擎：经 `get_event_call`（`socket/main.py`，`sio.call` 带超时）向本人生动会话发 `execute:python` RPC，`src/routes/+layout.svelte:556` 收到后送共享 Pyodide worker/沙箱执行，回调回传 `{stdout, stderr, result}`；
   - jupyter 引擎：经 `backend/open_webui/utils/code_interpreter.py` 连远端 Jupyter，base64 图片转换为 files 记录 URL。
   执行后 `ci_item['output']` 就地填充、`status='completed'`，追加 assistant message item 并 `convert_output_to_messages(raw=True)` 把“代码+输出”回流给模型继续分析；全部 output 落库 `ChatMessage.output`。前端按 output item 渲染，代码块内嵌 `attributes.output` 恢复上次运行结果，用户可编辑重跑、保存回写消息。

2. **Artifact 链**（模型自由文本代码块探测）：
   模型输出 ` ```html/css/js ` 或内联 `<html>/<style>/<script>` → `src/lib/utils/index.ts` 的 `getCodeBlockContents` 分组提取 → `Chat.svelte` 的 `getContents` 组装完整 HTML 文档 → 内容 store → `Artifacts.svelte` 侧栏 iframe 预览（CSP 注入 + sandbox）。关闭面板后内容仍是消息正文的一部分；重新打开聊天即重新派生。无独立持久化对象。

3. **工具结果物化链**：工具执行后 `process_tool_result` 分出文件、嵌入与引用 sources 三类结果，经 `files`/`embeds` 事件分别进入 `message.files`、`message.embeds`（FullHeightIframe 渲染）与 `message.sources`（Citations），全部落库为 ChatMessage 的 JSON 列（`backend/open_webui/models/chat_messages.py:142-150`）。

## 1. 触发方式、输出协议与对象模型

**代码解释器**：私有 XML 标记协议，不是 typed part。
- **协议与注入**：legacy 模式的系统提示注入（`backend/open_webui/config.py:456-471`）要求用 `<code_interpreter>` 标签包裹后立即停止；native function-calling 模式改由内置工具执行，不再用标签探测。
- **五重门控**：XML 检测还要求请求的 `function_calling` 为 legacy，之后才检查功能开关、模型内置工具标记、全局配置、模型 capabilities 与用户权限（`backend/open_webui/utils/middleware.py:4583-4598`）。
- **流式检测**：检测器 `tag_output_handler`（`middleware.py:3792`）用“已扫描长度 + 回看窗口”处理半截流，`extract_attributes` 解析标签属性（lang/type），结束标签出现时 `end=True` 立即收口（`middleware.py:4773-4781`）。误触发风险由门控和标签完整性共同控制。
- **防重跑回填**：`convert_output_to_messages` 中 `open_webui:code_interpreter` 和 output 文本会转成 `<code_interpreter>`/`<code_interpreter_output>` 回填（`backend/open_webui/utils/misc.py:445-462`），防止模型重跑。

**对象模型**：唯一具备稳定 ID 的输出对象是 Responses API 风格 output item（`middleware.py:3912-3921`），结构为：

```text
{ type: 'open_webui:code_interpreter', id: output_id('ci'), status, attributes, lang, code, output, duration }
```

输出项由 `output_id` 生成 ID，`status` 从 `in_progress` 到 `completed/failed/incomplete`，与其他 output item 类型并列存储于消息的 `output` JSON 列（`models/chat_messages.py:142`）。并列类型为：

```text
message / reasoning / function_call / function_call_output / open_webui:code_interpreter
```

事实源是聊天消息（`ChatMessage` 表），文件与运行实例都不是事实源。Artifact 无对象模型——没有 ID、状态或版本字段，只是渲染侧的派生内容。

**Artifact**：纯自由文本探测，无协议、无转义设计。`getCodeBlockContents`（`src/lib/utils/index.ts:2072`）以代码围栏正则提取代码块，按 lang 分组（html 开新组，css/js 追加），fallback 用内联 `<html>/<style>/<script>` 正则。半截流由 `hasClosingCodeFence(raw)`（`src/lib/components/chat/Messages/ContentRenderer.svelte:135`）判断“闭合代码围栏后才自动打开面板”，避免流式途中误触发。

## 2. 增量生成、更新与最终化

- 代码解释器：流式 chunk 直接追加到 `output[-1]['code']`（`middleware.py:4704-4707`），属于“逐 token 注入 + 结束标签收口”，无 AST/节点级更新。
- 执行循环（`middleware.py:5325-5498`）：消息结束时若最后一个 item 是 `open_webui:code_interpreter` 则进入；每次先 `chat:completion` 推送中间状态，执行（pyodide/jupyter），失败重试最多 5 次，成功后 `ci_item['output']` 就地写入、`status='completed'`，追加空 message item 再请求模型续写；模型仍输出代码解释器标签则继续循环。取消时以 `output` 半成品落库（`middleware.py:5567-5585`）。
- Artifact：无增量机制，消息渲染完整后才派生。
- 工具文件/嵌入：事件流（`files`/`embeds`，`middleware.py:1291-1309`）增量进入前端消息对象并随消息保存。

## 3. 投影表面与多视图关系

- 代码解释器：inline——消息内代码块（`CodeBlock.svelte`）＋运行结果区（STDOUT/STDERR、RESULT、base64 图片，`CodeBlock.svelte:591-631`）；同一代码块同时是编辑器（CodeMirror，`src/lib/components/common/CodeEditor.svelte`）。
- Artifact：sidecar——聊天右侧 Pane 面板（`ChatControls.svelte:446-447`），只读 iframe/SVG；版本切换遍历同一消息派生的多个 HTML 组（`Artifacts.svelte:137-186`）。同一对象无多同步投影：artifact 面板与消息代码块是“源与预览”关系，代码块改动不会即时同步到已打开的面板。
- Pyodide 文件系统：sidecar——ChatControls 的 Files 标签页（`ChatControls.svelte:377-380`，选择 Terminal 时用终端 FileNav，否则用 PyodideFileNav）；执行后 `window.dispatchEvent(new Event('pyodide:files'))` 触发自动刷新（`CodeBlock.svelte:344-345`）。
- 终端工作区：sidecar——FileNav 面板内含文件预览（图片/视频/音频/PDF/SQLite/Office/ipynb/文本/代码）、端口预览 iframe（`PortPreview.svelte`，代理 URL + 浏览器式导航栏）、底部 xterm 终端（`XTerminal.svelte`）。工具 `display_file`/`write_file` 事件驱动面板跳转（`+layout.svelte:475-483`、`FileNav.svelte:853-902`）。
- 工具结果：inline——`message.files`（文件卡片/图片）、`message.embeds`（`FullHeightIframe`，`ResponseMessage.svelte:711-728`）、`message.sources`（Citations 组件，源文档 iframe 弹窗带 CSP）。

## 4. 表现类型、依赖与运行环境

- 代码执行：两个引擎。**Pyodide**（默认）：`createPyodideWorker`（`src/lib/pyodide/createPyodideWorker.ts:7-10`）按 `features.enable_pyodide_file_persistence` 选择真实 Worker 或隐藏 iframe 沙箱：
  - worker 模式加载 `loadPyodide` + micropip 按需装包（`src/lib/workers/pyodide.worker.ts:22-74`），matplotlib 的 `plt.show` 被 patch 成 base64 PNG 打印（`pyodide.worker.ts:193-220`）；
  - iframe 沙箱模式 `sandbox="allow-scripts"`、隐藏、经 postMessage 通信（`pyodideSandboxHost.ts:196-288`），同一份代码逻辑内嵌在 `sandboxScript`。
  **Jupyter**：`JupyterCodeExecuter` 走 Jupyter REST API 建 kernel + WebSocket channels 执行，收集 stdout/stderr/execute_result/display_data（含 image/png base64）与 traceback（`backend/open_webui/utils/code_interpreter.py:69-189`）。
- 依赖提供：Pyodide 引擎由前端代码内 import 探测自动列包（requests/numpy/pandas/matplotlib 等，`CodeBlock.svelte:224-238`），micropip 安装；Jupyter 引擎依赖管理员配置的 Jupyter 服务器（token/password 认证，`config.py:440-450`）。
- HTML Artifact：完整 HTML/CSS/JS 文档跑在 `srcdoc` iframe 里。安全配置：`injectCsp` 注入 CSP（`src/lib/utils/csp.ts` + `$config?.ui?.iframe_csp`），sandbox 为 `allow-scripts allow-downloads`（可配 allow-forms/allow-same-origin，`Artifacts.svelte:246-260`）。外部导航被拦截（同源 pushState、异源阻止，`Artifacts.svelte:41-61`）；SVG 走 `SvgPanZoom` 本地渲染。
- 工具嵌入（embeds）：`FullHeightIframe` 渲染任意 HTML URL，带 `processHtmlForDeps`（Alpine/Chart.js 依赖处理）、高度协商 postMessage（`FullHeightIframe.svelte:33-235`）。
- 终端：文件预览含 Office（mammoth/xlsx/pptx→图片）、SQLite（浏览器内 SqliteView）、notebook（ipynb 单元格渲染 + Jupyter 会话执行）。RAG 检索结果呈现为 citations/sources，不执行代码。

## 5. 用户交互、事件与错误反馈

- 代码块：编辑（CodeMirror）→ Run（pyodide 本地执行或 `executeCode` API→Jupyter，`CodeBlock.svelte:142-221`），60 秒超时（`CodeBlock.svelte:259-268`，超时后终止并重建非共享 worker），结果按 stdout/stderr/result/图片分区展示；执行中按钮显示 Running、禁用重复点击。
- 历史结果恢复：`attributes.output`（来自消息 output item 的序列化结果）在挂载时恢复上次运行输出（`CodeBlock.svelte:404-419`）。
- 结构化输出折叠卡：reasoning/function_call/code_interpreter 类型的 output item 按 `buildOutputDisplayItems`（`structuredOutput.ts:266-333`）渲染为 `detail_group`/`detail_single`，`done` 状态驱动 “Thinking.../Analyzing...” 与完成态切换；tool_calls 用 `ToolCallDisplay` 显示参数与结果。
- 错误反馈：执行错误进 `stderr`（含 Python traceback、Jupyter 超时信息、event_caller 会话断开错误），消息级错误走 `get_message_error_content` 的 error 事件；前端 toast 提示。
- 交互状态恢复：`CodeExecutions` 徽章列表（名称/成功/失败/运行中）和 `CodeExecutionModal`（代码+输出+文件链接）由 `message.code_executions` 驱动——该字段本次未在后端模型中找到写入路径，属未确认事项。

## 6. 编辑、diff、版本与协作

- 代码块编辑保存：保存从代码块组件一路走到消息渲染层（`ResponseMessage.svelte:850-874`）：在 `sourceMessage.output` 上以 `replaceOutputMessageText`（`structuredOutput.ts:343-380`，按文本包含匹配替换第一个 message item 内容）或全文 `content.replace(raw, ...)`，然后 `updateChat()` 持久化。整块覆盖，无 diff、无撤销、无版本。
- 整条消息编辑：`OutputEditView`（视觉行编辑器 + CodeMirror JSON 双模式，`OutputEditView.svelte:21-86`）编辑 `message.output` 数组本身（可删行、改文本），Save/Save As Copy 走 `editMessage` API（`ResponseMessage.svelte:411-440`）。
- Notebook（终端）：单元格内联编辑（textarea/CodeMirror `CellEditor`），Run/Run All/Restart/Stop，执行输出（text/html/image/error）就地写入 cell，编辑先于执行应用（`NotebookView.svelte:158-194`）；但 cell 改动与输出的**回写持久化到 .ipynb 文件**本次未找到（`FilePreview` 的 ipynb 保存路径未确认）。
- 终端文件：文本/代码/markdown 文件可编辑并 `uploadToTerminal` 回写（`FileNav.svelte:1368-1379`），整体覆盖。
- 无 CRDT、无并发冲突处理、无分支；版本概念仅存在于 Artifact 面板“上一版/下一版”（同一消息的多个 HTML 组，非内容版本历史）。

## 7. 能力桥、执行位置与权限范围

- **Pyodide（浏览器内 WASM）**：代码跑在真实 Worker 或隐藏 iframe，沙箱属性与宿主桥命令如下（`pyodide.worker.ts:265-317`）：

  ```text
  sandbox="allow-scripts"（无 allow-same-origin / allow-forms / allow-modals）
  文件进出经宿主桥：fs:upload / fs:list / fs:read / fs:delete / fs:mkdir / fs:sync
  ```

  无网络授权（Python `requests` 包可装，但浏览器沙箱无跨域出网通道——CORS/混合内容由浏览器决定，未专门配置代理）；`/mnt/uploads` 是唯一约定目录。后端→浏览器的执行桥是 `sio.call` RPC，仅限请求用户自己的活动会话（`socket/main.py:1100-1128`），超时/断开返回 error。
- **Jupyter（远端）**：后端进程直接连用户配置的 Jupyter 服务器（token/password），执行位置与网络能力属管理员环境；`CODE_INTERPRETER_BLOCKED_MODULES` 可注入 import 拦截（`builtin.py:526-549`，仅对 `__main__` 直接 import 生效）。
- **终端服务器（远端）**：文件、进程、端口、notebook 全部委托外部 Open WebUI Terminal 服务；能力桥是 HTTP API + WebSocket，凭据为 bearer key 或会话 token（`FileNav.svelte:235-249`）。
- 模型在 pyodide 引擎下经系统提示被告知“不能装包、沙箱无网络”（`config.py:474-486`），属提示级约束，非强制。

## 8. 持久化、恢复、分享与导出

- 事实源：`ChatMessage` 表（`chat_messages.py:128-150`）有五列 JSON 存储（清单见下）；`Chats.upsert_message_to_chat_by_id_and_message_id` 随流式事件持续写入（`middleware.py:4160-4168`、`5513-5536`）。重新打开聊天即从 `/api/v1/chats/{id}` 恢复历史，渲染器按 `output` 重建代码块及 `attributes.output` 历史结果。JSON 列清单：

  ```text
  content / output / files / sources / embeds
  ```
- 代码解释器输出图片：base64 → `upload_image` → files 表 + URL（`middleware.py:5415-5440`、`builtin.py:609-643`），消息里留 `![Output Image](url)`，可下载。
- 图像生成工具：图片文件 URL 经 `Chats.add_message_files_by_id_and_message_id` 挂到消息（`builtin.py:388-405`）。
- Pyodide 文件系统：仅当 `ENABLE_PYODIDE_FILE_PERSISTENCE=true`（`backend/open_webui/env.py:1137`）时 worker 模式挂 IDBFS 到 IndexedDB 并 `syncfs` 持久化（`pyodide.worker.ts:49-73`、`96-105`）；隐藏 iframe 沙箱模式无持久化，刷新即失。默认关闭。
- 导出/分享：Artifact 可下载单 HTML 文件（`Artifacts.svelte:82-92`）、复制；终端文件可下载（目录打包 ZIP，`FileNav.svelte:526-552`）；Pyodide 文件可下载；消息分享/导出属 Chat 类目，此处不展开。

## 9. 模型回流、对象感知与持续维护

- 闭环最强的是代码解释器：执行结果就地写入同一 `ci_item`（ID 不变），`convert_output_to_messages(raw=True)` 把 `<code_interpreter>`+`<code_interpreter_output>` 拼进后续请求（`misc.py:445-462`），模型据此**继续迭代而不会重新生成同一份代码**；执行循环最多 5 轮由模型决定何时停。
- Pyodide 文件系统是会话级活对象：模型在 `/mnt/uploads` 读写文件（提示注入，`config.py:481-486`），同一 worker 跨多次执行保持状态，用户文件浏览器可见、可下载；模型侧无“对象列表/状态查询 API”——它只能通过文件系统操作感知，且消息上下文仅含文本化的输出。
- 工具结果：以 files/embeds/sources 挂到消息，模型通过 citations/文件内容（后续消息重取文件）间接感知，无对象寻址协议。
- Artifact：完全无回流——模型无法感知用户是否预览、无法定向修改某个 artifact；用户编辑 artifact 代码只能通过编辑消息代码块并保存（回写 content/output），模型下一轮能读到该内容，但这不是对象级维护。
- 用户编辑后的消息（含 output）参与后续上下文装配（`convert_output_to_messages`），故“编辑→再生成”在消息级成立。

## 10. 生命周期、资源治理与性能

- Pyodide worker：页面级共享单例（`pyodideWorker` store，`CodeBlock.svelte:245-247`、`PyodideFileNav.svelte:100-107`），执行 60 秒超时；非共享临时 worker 在组件销毁时 `terminate()`（`CodeBlock.svelte:427-432`），共享 worker 超时时终止并置空 store 以便重建（`+layout.svelte:340-348`）。隐藏 iframe 沙箱在 `terminate()` 时从 DOM 移除。
- Jupyter kernel：每次执行新建 kernel，上下文退出时删除（`code_interpreter.py:60-67`）——即无跨调用状态保持。
- Notebook 会话：前端持有 sessionId，组件销毁时 `stopNotebookSession`（`NotebookView.svelte:213-215`）。
- 长输出：stdout 超过 100 行限高滚动（`CodeBlock.svelte:605-608`）；执行结果按需拉取（files 内容读取是懒加载）。未发现定时器/动画/WebGL 登记与暂停机制（本类目无相关对象）；多会话并发时共享 worker 以 `id` 匹配响应（`pyodide.worker.ts:242-259`），同一 worker 串行处理。

## 11. 测试、已确认边界与未验证事项

- 测试资产：本快照 `test/` 仅有 `test_files/image_gen/sd-empty.pt`（占位文件）；前端唯一测试 `src/lib/shortcuts.test.ts`。本次未找到针对代码解释器、Artifact、notebook、pyodide 文件系统、output 持久化恢复的自动化测试。
- 已确认边界（源码直接可见）：
  - 代码解释器是唯一有稳定 ID + 状态 + 就地更新的输出对象；Artifact 无对象身份；
  - Artifact 面板内容总是由当前 history 派生（`Chat.svelte getContents`），关闭面板不销毁消息内容，重开聊天即重建——派生视图而非持久对象；
  - Pyodide 跨会话持久化默认关闭（env 默认 false）；
  - Jupyter 引擎每次执行新 kernel，无状态保持；
  - 编辑保存粒度是整块覆盖；无 diff/接受拒绝/版本/冲突处理。
- 未验证事项（未运行）：
  - 浏览器端一切行为：Pyodide 实际执行、iframe CSP 注入效果、xterm 连接、Office/PDF/SQLite 预览、面板布局与拖拽；
  - `ENABLE_REALTIME_CHAT_SAVE` 实时保存分支与取消中断路径的输出完整性；
  - 共享 worker 在多标签页/多并发执行下的真实行为；
  - `message.code_executions` 字段的后端写入路径（前端有渲染组件，本次未找到写入方）；
  - notebook 编辑/执行结果是否持久化回 .ipynb 文件；
  - 模型经 `execute:python` RPC 在无浏览器活动会话（后台标签）时的可用性（代码有 session 校验与超时提示，未运行确认）。
- 能力等级（横向对比口径，不表示产品成熟度）：**G3（可执行 Artifact：Pyodide/Jupyter 代码执行、HTML 沙箱预览、工具结果物化）为主体，部分 G4（代码块与 notebook 单元编辑保存、文件编辑回写，但无 diff/版本/接受拒绝）与部分 G5（模型可读写沙箱文件系统、同一输出项就地更新并回流，但仅会话级、无对象查询协议、默认不跨会话持久化）**。各轴单列：
  - 协议开放度：私有 XML 标记 + 代码块探测（低开放）；
  - 更新粒度：整块+就地字段（低）；
  - 投影表面：inline + sidecar（无 canvas/desktop）；
  - 执行强度：WASM 沙箱 / 远端 Jupyter / 远端进程（中）；
  - 持续性：消息持久化 + 会话级文件系统（中）；
  - 闭环程度：可执行、可编辑、可回流（中）；
  - 能力范围：无网络授权默认、文件经宿主桥（窄）；
  - 可移植性：artifact 单文件可下载、其余仅宿主可用（低）。

## 12. 关键源码索引

- `backend/open_webui/utils/middleware.py:3792` `tag_output_handler`：流式标签检测与 output item 创建；`:4129` 门控；`:5325` 执行循环；`:5457` 执行后回流续写
- `backend/open_webui/utils/misc.py:257` `convert_output_to_messages`：output item → 模型消息回流（含 code_interpreter 重注入）
- `backend/open_webui/utils/code_interpreter.py:25` `JupyterCodeExecuter`：Jupyter 引擎
- `backend/open_webui/tools/builtin.py:496` `execute_code`：内置代码解释器工具；`:358` `generate_image`
- `backend/open_webui/utils/files.py:83` `get_image_url_from_base64`：base64 输出物化为文件 URL
- `backend/open_webui/socket/main.py:1100` `get_event_call`：`execute:python` RPC 桥（sio.call）
- `backend/open_webui/models/chat_messages.py:128` `ChatMessage`：output/files/sources/embeds 持久化
- `src/routes/+layout.svelte:288` `executePythonAsWorker`：RPC 侧执行与回调
- `src/lib/workers/pyodide.worker.ts:177` `executeCode`：worker 执行与 IDBFS 持久化
- `src/lib/pyodide/pyodideSandboxHost.ts:196` `PyodideSandboxHost`：隐藏 iframe 沙箱
- `src/lib/components/chat/Messages/CodeBlock.svelte:142` `executePython`：代码块 Run/Save/历史结果恢复
- `src/lib/components/chat/Messages/structuredOutput.ts:266` `buildOutputDisplayItems`：output item → 展示模型
- `src/lib/components/chat/Messages/ResponseMessage.svelte:850`：代码块保存回写消息
- `src/lib/components/chat/Artifacts.svelte`：artifact 侧栏；`src/lib/utils/index.ts:2072` `getCodeBlockContents`；`src/lib/components/chat/Chat.svelte:1638` `getContents`
- `src/lib/components/chat/PyodideFileNav.svelte`：Pyodide 文件浏览器
- `src/lib/components/chat/FileNav.svelte`：终端工作区；`src/lib/components/chat/FileNav/NotebookView.svelte`：notebook 渲染与执行
