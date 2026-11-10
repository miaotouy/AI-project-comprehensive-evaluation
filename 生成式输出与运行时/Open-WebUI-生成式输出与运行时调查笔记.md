# Open WebUI 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/open-webui/open-webui`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`c38885a1a737da4968f157092f304f3b5481d0bf`（分支：`main`）
>
> 调查方式：静态代码阅读，grep/glob 覆盖前后端关键词（artifact、code interpreter、pyodide、jupyter、iframe、notebook、embeds、files、execute），沿“生成->物化->展示->执行->编辑->保存->回流”链路逐段核对；未运行构建、服务或任何执行流程
>
> 调查范围：模型输出对象（代码解释器、HTML/SVG Artifact、工具结果文件/嵌入、Pyodide 与终端文件系统、notebook）的对象模型、投影、执行环境、编辑与持久化、模型回流。排除：消息渲染器通用 Markdown/高亮/KaTeX/静态 Mermaid 细节、Agent 工具注册与调度语义、RAG 检索本身
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI 的生成式输出分散在一套“消息即事实源”的模型上：代码解释器输出是唯一具备完整“触发->执行->结果->展示->编辑->保存->重新打开->模型回流”生命周期的输出对象（Responses API 风格 `open_webui:code_interpreter` output item，持久化在 `ChatMessage.output` JSON 列）；HTML/CSS/JS Artifact 是消息正文代码块的派生投影（侧栏 iframe），无独立对象身份、不可编辑、不可回流；Pyodide 文件系统是浏览器沙箱内的会话级活文件系统（可跨会话持久化但默认关闭）；终端工作区（文件浏览、notebook、端口预览）全部委托给外部 Terminal 服务器。代码执行引擎三选一：浏览器 Pyodide（WASM worker 或隐藏 iframe 沙箱）、远端 Jupyter（REST+WebSocket）、外部终端服务器。能力等级判定：**G3 为主（可执行 Artifact + 会话内活对象），兼具 G4 的部分特征（代码块/notebook 单元编辑保存、文件编辑回写）与 G5 的会话级局部（模型可读写 `/mnt/uploads` 并就地更新同一输出项）**；无 diff/版本/接受拒绝、无跨会话对象保证、无多投影同步。

## 系统边界与总体调用链

两类主要输出链路：

1. **代码解释器链**（legacy function-calling 模式下由模型自由文本触发，XML 标签协议）：
   模型流式输出 `<code_interpreter>` 标签，流式检测器 `tag_output_handler` 边扫边切分消息，为每段代码建立 `open_webui:code_interpreter` output item 并逐 chunk 累积代码；流结束后由 `middleware.py:5325` 进入执行循环，最多 5 轮：
       - pyodide 引擎：后端经 `get_event_call` 向该用户自己的活动会话发 `execute:python` RPC，调用带超时；前端收到后交给共享 Pyodide worker 或隐藏沙箱执行，再把 stdout、stderr 与 result 回传后端（`backend/open_webui/socket/main.py`、`src/routes/+layout.svelte:556`）；
   - jupyter 引擎：后端经 `backend/open_webui/utils/code_interpreter.py` 连远端 Jupyter，把结果中的 base64 图片转成 files 记录 URL。
   执行完成后，输出就地写进这个 output item 并标记为 completed；后端追加一条 assistant message item，用 `convert_output_to_messages(raw=True)` 把“代码+输出”回流给模型继续分析，所有 output 随 `ChatMessage.output` 落库。前端按 output item 渲染，代码块内嵌 `attributes.output` 恢复上次运行结果，用户可编辑重跑、保存回写消息。

2. **Artifact 链**（模型自由文本代码块探测）：
   模型自由文本里的 html/css/js 代码块，或直接内联的整页 HTML 标签，经提取、拼装后送侧栏 iframe 预览（CSP 注入 + sandbox）。提取、组装与预览分属三个入口：

   ```text
   src/lib/utils/index.ts   getCodeBlockContents   按围栏正则切块，按 lang 分组（html 开新组，css/js 追加），内联标签作 fallback
   Chat.svelte              getContents            组装完整 HTML 文档写入内容 store
   Artifacts.svelte         侧栏 iframe 预览
   ```

   关闭面板后内容仍是消息正文的一部分；重新打开聊天即重新派生。无独立持久化对象。

3. **工具结果物化链**：工具执行后，结果按文件、嵌入与引用三类分流，分别写进消息的一个 JSON 列，并与消息一起持久化。终端文件工具的结果无论是否传 `inline` 都会物化为文件结果，`inline=true` 只额外带 `displayed` 标记；前端默认不在消息里内联渲染该文件块，仅当结果带 `displayed` 或用户把终端文件显示设为 inline 时渲染，其余情况由 `terminal:display_file` 事件驱动右侧 FileNav 面板。

   ```text
   分流           process_tool_result      backend/open_webui/utils/middleware.py:258-292
   文件           files 事件 → message.files
   嵌入           embeds 事件 → message.embeds    FullHeightIframe 渲染
   引用           sources → message.sources       Citations 组件
   前端显示判定    src/lib/components/chat/Messages/structuredOutput.ts:166-186
                  StructuredOutputRenderer.svelte:164-169
   终端文件联动    display_file → terminal:display_file 事件 → 右侧 FileNav 面板
                  src/lib/components/chat/Chat.svelte:1144-1149
   落库           ChatMessage 表 JSON 列：backend/open_webui/models/chat_messages.py:142-150（files / embeds / sources 三列）
   ```

## 1. 触发方式、输出协议与对象模型

**代码解释器**：模型用私有 XML 标签声明要执行的代码，后端在流式文本里识别标签并转换为 output item。
- **协议与注入**：legacy 模式下系统提示要求模型把代码包进 `<code_interpreter>` 标签、输出后立即停止；native function-calling 模式改由内置工具执行，标签不再参与探测（`backend/open_webui/config.py:456-471`）。
- **门控**：请求必须使用 legacy function-calling，后端才继续检查功能开关、模型内置工具标记、全局配置、模型能力声明与用户权限，条件全部满足才把标签当作执行指令。
- **流式检测**：检测器在“已扫描长度 + 回看窗口”范围内处理半截流，解析标签属性（lang/type），结束标签一出现就以 end 标记立即收口，误触发由门控与标签完整性共同约束（`backend/open_webui/utils/middleware.py:3792-4781`）。
- **防重跑回填**：回流前把 output item 与 output 文本改写成 `<code_interpreter>` 和 `<code_interpreter_output>` 标签，模型看到自己此前的代码与结果，避免重复生成（`backend/open_webui/utils/misc.py:445-462`）。

**对象模型**：唯一具备稳定 ID 的输出对象是 Responses API 风格 output item（`middleware.py:3912-3921`），结构为：

```text
{ type: 'open_webui:code_interpreter', id: output_id('ci'), status, attributes, lang, code, output, duration }
```

输出项由 `output_id` 生成 ID，状态从 in_progress 走到 completed、failed 或 incomplete，并与其他 output item 类型并列存放于消息的 `output` JSON 列（`models/chat_messages.py:142`）。并列类型为：

```text
message / reasoning / function_call / function_call_output / open_webui:code_interpreter
```

事实源是聊天消息（`ChatMessage` 表），文件与运行实例都不是事实源。Artifact 无对象模型——没有 ID、状态或版本字段，只是渲染侧的派生内容。

**Artifact**：纯自由文本探测，无协议、无转义设计。`getCodeBlockContents`（`src/lib/utils/index.ts:2072`）以代码围栏正则提取代码块，按 lang 分组（html 开新组，css/js 追加），fallback 用内联 `<html>/<style>/<script>` 正则。半截流由 `hasClosingCodeFence(raw)`（`src/lib/components/chat/Messages/ContentRenderer.svelte:135`）判断“闭合代码围栏后才自动打开面板”，避免流式途中误触发。

## 2. 增量生成、更新与最终化

- 代码解释器：流式 chunk 直接追加进当前 output item 的 code 字段，属于“逐 token 注入 + 结束标签收口”，没有 AST 或节点级更新（`middleware.py:4704-4707`）。
- 执行循环：消息结束时若最后一个 item 是 `open_webui:code_interpreter`，后端进入执行循环。每轮先经 `chat:completion` 推送中间状态，再按引擎执行 pyodide 或 jupyter，失败最多重试 5 次；成功后输出就地写回该 item 并标记 completed，追加一个空 message item 请求模型续写，模型继续输出标签则再进一轮。用户取消时以半成品 output 落库（`middleware.py:5325-5585`）。
- Artifact：没有增量机制，消息渲染完整后才从正文派生。
- 工具文件与嵌入：通过 files 与 embeds 事件增量进入前端消息对象，随消息一起保存（`middleware.py:1291-1309`）。

## 3. 投影表面与多视图关系

- 代码解释器：inline 投影，代码与运行结果同处消息内。结果区展示 STDOUT/STDERR、RESULT 与 base64 图片，同一块代码还兼作 CodeMirror 编辑器（`src/lib/components/chat/Messages/CodeBlock.svelte:591-631`、`src/lib/components/common/CodeEditor.svelte`）。
- Artifact：sidecar 投影，落在聊天工作台的 artifacts 标签页（`ChatTabs/tabs.ts` 定义该标签型），以只读 iframe 或内联 SVG 呈现；切换版本时遍历同一消息派生的多个 HTML 组（`Artifacts.svelte:137-186`）。面板与消息代码块是“源与预览”关系，代码块改动不会即时同步到已打开的面板。
- Pyodide 文件系统：sidecar 投影，位于工作台的 files 标签页；引擎选择 Terminal 时复用终端 FileNav，否则用 `PyodideFileNav.svelte`。一次执行结束后页面派发 `pyodide:files` 事件，文件列表随之自动刷新（`CodeBlock.svelte:344-345`）。
- 终端工作区：sidecar 投影，右侧 FileNav 面板承担三类工作：
  - 文件预览：图片、视频、音频、PDF、SQLite、Office、ipynb 与文本代码；
  - 端口预览：由 `ChatTabs/Browser.svelte` 的浏览器会话渲染 iframe，带代理 URL 与浏览器式导航栏；
  - 底部终端：`XTerminal.svelte` 提供 xterm 会话。

  工具事件驱动面板跳到对应文件；Office 预览先向终端服务器索取服务端渲染的 PDF，拿不到时回落到浏览器端 docx/pptx 渲染。两个环节的入口如下：

  ```text
  面板跳转        display_file / write_file → src/routes/+layout.svelte:475-483
  服务端 PDF      downloadFilePreview → GET /files/view?path=…&preview=true
  回落落点        src/lib/components/chat/FileNav.svelte:868-940
  docx/pptx 渲染  FileNav/FilePreview.svelte、Messages/TerminalOutputFile.svelte:143-200
  ```
- 工具结果：inline——`message.files`（文件卡片/图片）、`message.embeds`（`FullHeightIframe`，`ResponseMessage.svelte:711-728`）、`message.sources`（Citations 组件，源文档 iframe 弹窗带 CSP）。

## 4. 表现类型、依赖与运行环境

- 代码执行由两个引擎承担，默认走 **Pyodide**。Pyodide 由 `createPyodideWorker` 按 `features.enable_pyodide_file_persistence` 选择真实 Worker 或隐藏 iframe 沙箱（`src/lib/pyodide/createPyodideWorker.ts:7-10`）：
  - worker 模式加载 Pyodide 运行时，用 micropip 按需装包，matplotlib 的 plt.show 被 patch 成打印 base64 PNG（`src/lib/workers/pyodide.worker.ts:22-220`）；
  - iframe 沙箱模式隐藏运行，只开 allow-scripts 权限，经 postMessage 与宿主通信，同一套代码逻辑内嵌在沙箱脚本里（`src/lib/pyodide/pyodideSandboxHost.ts:196-288`）。
  **Jupyter** 引擎由 `JupyterCodeExecuter` 走 Jupyter REST API 建 kernel，再用 WebSocket channels 执行，收集 stdout/stderr、execute_result/display_data（含 image/png base64）与 traceback（`backend/open_webui/utils/code_interpreter.py:69-189`）。
- 依赖提供：Pyodide 引擎由前端代码内 import 探测自动列包（requests/numpy/pandas/matplotlib 等，`CodeBlock.svelte:224-238`），micropip 安装；Jupyter 引擎依赖管理员配置的 Jupyter 服务器（token/password 认证，`config.py:440-450`）。
- HTML Artifact：完整 HTML/CSS/JS 文档跑在 `srcdoc` iframe 里。安全边界由 CSP 注入与 sandbox 白名单共同划定，外部导航一律拦截；SVG 走本地平移缩放渲染。

  ```text
  CSP 注入     injectCsp（src/lib/utils/csp.ts + $config?.ui?.iframe_csp）
  sandbox      allow-scripts allow-downloads，可另配 allow-forms / allow-same-origin（Artifacts.svelte:246-260）
  导航拦截     同源 pushState、异源阻止（Artifacts.svelte:41-61）
  SVG 渲染     SvgPanZoom
  ```
- 工具嵌入（embeds）：`FullHeightIframe` 渲染任意 HTML URL，带 `processHtmlForDeps`（Alpine/Chart.js 依赖处理）、高度协商 postMessage（`FullHeightIframe.svelte:33-235`）。
- 终端：文件预览含 Office（mammoth/xlsx/pptx→图片）、SQLite（浏览器内 SqliteView）、notebook（ipynb 单元格渲染 + Jupyter 会话执行）。RAG 检索结果呈现为 citations/sources，不执行代码。

## 5. 用户交互、事件与错误反馈

- 代码块：在 CodeMirror 里改完代码点 Run，选 pyodide 就本地执行，选 `executeCode` 则走 API 交给 Jupyter；单次执行 60 秒超时，超时后终止并重建一个非共享 worker，结果按 stdout、stderr、result 与图片分区展示。执行期间按钮显示 Running 并禁用重复点击（`CodeBlock.svelte:142-268`）。
- 历史结果恢复：组件挂载时读取 output item 序列化出的 `attributes.output`，把上次运行结果放回代码块下方（`CodeBlock.svelte:404-419`）。
- 结构化输出折叠卡：reasoning、function_call 与 code_interpreter 三类 output item 由 `buildOutputDisplayItems` 归并成单条或分组卡片，done 状态一到就从 Thinking.../Analyzing... 切到完成态；tool_calls 另用 `ToolCallDisplay` 显示参数与结果（`structuredOutput.ts:266-333`）。
- 错误反馈：执行错误写进 stderr，Python traceback、Jupyter 超时与会话断开都从这里露出；消息级错误通过 error 事件交给前端 toast 提示（`get_message_error_content`）。
- 交互状态恢复：`CodeExecutions` 徽章列表按名称、成功、失败与运行中分组，`CodeExecutionModal` 展示代码、输出与文件链接，两者都由 `message.code_executions` 驱动。该字段本次未在后端模型中找到写入路径，属未确认事项。

## 6. 编辑、diff、版本与协作

- 代码块编辑保存：代码块组件把改动交给消息渲染层，由它在 `sourceMessage.output` 上按文本包含匹配替换第一条 message item，或对整条 content 做字符串替换，再调 `updateChat()` 持久化（`ResponseMessage.svelte:850-874`、`structuredOutput.ts:343-380`）。保存按整块覆盖，没有 diff、撤销或版本。
- 整条消息编辑：`OutputEditView` 提供视觉行编辑与 CodeMirror JSON 两种模式，直接改 `message.output` 数组（可删行、改文本），Save 与 Save As Copy 走 `editMessage` API（`OutputEditView.svelte:21-86`、`ResponseMessage.svelte:411-440`）。
- Notebook（终端）：单元格内联编辑（textarea 或 CodeMirror），支持 Run/Run All/Restart/Stop，执行输出（text/html/image/error）就地写进 cell，编辑先于执行生效（`NotebookView.svelte:158-194`）；cell 改动与输出的**回写持久化到 .ipynb 文件**本次未找到，`FilePreview` 的 ipynb 保存路径未确认。
- 终端文件：文本、代码与 markdown 文件可编辑，保存时经 `uploadToTerminal` 整体覆盖回写（`FileNav.svelte:1368-1379`）。
- 无 CRDT、无并发冲突处理、无分支；版本概念仅存在于 Artifact 面板“上一版/下一版”（同一消息的多个 HTML 组，非内容版本历史）。

## 7. 能力桥、执行位置与权限范围

- **Pyodide（浏览器内 WASM）**：代码跑在真实 Worker 或隐藏 iframe，沙箱属性与宿主桥命令如下（`pyodide.worker.ts:265-317`）：

  ```text
  sandbox="allow-scripts"（无 allow-same-origin / allow-forms / allow-modals）
  文件进出经宿主桥：fs:upload / fs:list / fs:read / fs:delete / fs:mkdir / fs:sync
  ```

  沙箱没有网络授权：Python 的 requests 包能装上，但浏览器沙箱没有跨域出网通道，CORS 与混合内容最终由浏览器裁决，也没有专门配置代理。`/mnt/uploads` 是唯一约定目录。后端到浏览器的执行桥是 `sio.call` RPC，只对发起请求的用户自己的活动会话开放，超时或断开时返回 error（`backend/open_webui/socket/main.py:1100-1128`）。
- **Jupyter（远端）**：后端进程直接连用户配置的 Jupyter 服务器，凭 token 或 password 认证，执行位置与网络能力取决于管理员环境。管理员可通过 `CODE_INTERPRETER_BLOCKED_MODULES` 注入 import 拦截，该拦截只对 `__main__` 的直接 import 生效（`backend/open_webui/tools/builtin.py:526-549`）。
- **终端服务器（远端）**：文件、进程、端口、notebook 全部委托外部 Open WebUI Terminal 服务；能力桥是 HTTP API + WebSocket，凭据为 bearer key 或会话 token（`FileNav.svelte:235-249`）。
- 模型在 pyodide 引擎下通过系统提示得知“不能装包、沙箱无网络”，这属于提示级约束，代码层不做强制校验（`config.py:474-486`）。

## 8. 持久化、恢复、分享与导出

- 事实源：`ChatMessage` 表，五个 JSON 列承载输出（清单见下）。流式过程中的写入都走 `Chats.upsert_message_to_chat_by_id_and_message_id`（`backend/open_webui/models/chat_messages.py:128-150`、`backend/open_webui/utils/middleware.py:4160-5536`）。
- 恢复：重新打开聊天即从 `/api/v1/chats/{id}` 拉历史，渲染器按 `output` 列重建代码块与 `attributes.output` 历史结果。JSON 列清单：

  ```text
  content / output / files / sources / embeds
  ```
- 代码解释器输出图片：执行结果里的 base64 图片经 `upload_image` 存成 files 记录并换成 URL，消息正文留下 `![Output Image](url)` 供下载（`backend/open_webui/utils/middleware.py:5415-5440`、`backend/open_webui/tools/builtin.py:609-643`）。
- 图像生成工具：图片以完整文件对象随事件回流并挂到消息，字段与两处写入口见下；在频道会话里调图时还会带上 `channel_id`/`message_id`，使生成图同时落到频道消息。

  ```text
  文件对象字段  id / url / name / content_type
  通用写入口    backend/open_webui/routers/images.py:552-560、tools/builtin.py:388-405
  频道消息双写  tools/builtin.py:391-398、utils/middleware.py:1773-1782
  ```
- Pyodide 文件系统：只有 `ENABLE_PYODIDE_FILE_PERSISTENCE=true` 时才启用持久化（`backend/open_webui/env.py:1137`）。worker 模式把 IDBFS 挂到 IndexedDB 并用 syncfs 落盘；隐藏 iframe 沙箱模式没有持久化，刷新即失。该开关默认关闭（`src/lib/workers/pyodide.worker.ts:49-105`）。
- 导出/分享：Artifact 可下载单 HTML 文件（`Artifacts.svelte:82-92`）、复制；终端文件可下载（目录打包 ZIP，`FileNav.svelte:526-552`）；Pyodide 文件可下载；消息分享/导出属 Chat 类目，此处不展开。

## 9. 模型回流、对象感知与持续维护

- 闭环最强的是代码解释器：执行结果就地写回同一个 output item，ID 保持不变，后续请求由 `convert_output_to_messages(raw=True)` 拼上 `<code_interpreter>` 与 `<code_interpreter_output>` 文本，模型据此**继续迭代而不会重新生成同一份代码**；执行循环最多 5 轮，何时停止由模型决定（`backend/open_webui/utils/misc.py:445-462`）。
- Pyodide 文件系统是会话级活对象：系统提示要求模型在 `/mnt/uploads` 下读写文件，同一个 worker 跨多次执行保持状态，用户能在文件浏览器里看到并下载这些文件。模型侧没有对象列表或状态查询接口，只能靠文件系统操作感知文件，消息上下文里也只有文本化的输出（`backend/open_webui/config.py:481-486`）。
- 工具结果：以 files、embeds 与 sources 三类挂到消息，模型通过 citations 或后续消息重取文件内容间接感知，没有对象寻址协议。
- Artifact：没有回流通道。模型既不知道用户有没有打开预览，也无法定向修改某一个 artifact；用户改 artifact 代码只能编辑消息里的代码块并保存，回写 content 与 output 后模型下一轮才能读到，这属于消息级修改。
- 用户编辑后的消息（含 output）参与后续上下文装配（`convert_output_to_messages`），故“编辑→再生成”在消息级成立。

## 10. 生命周期、资源治理与性能

- Pyodide worker：页面级共享单例，代码块组件与 Pyodide 文件浏览器共用同一个 store，单次执行限时 60 秒。非共享的临时 worker 在组件销毁时 terminate()，共享 worker 超时后也终止并清空 store，下次执行时重建；隐藏 iframe 沙箱在 terminate() 时从 DOM 移除（`src/lib/components/chat/Messages/CodeBlock.svelte:245-432`、`src/lib/components/chat/PyodideFileNav.svelte:100-107`、`src/routes/+layout.svelte:340-348`）。
- Jupyter kernel：每次执行新建一个 kernel，上下文退出时删除，因此连续调用之间不保留状态（`backend/open_webui/utils/code_interpreter.py:60-67`）。
- Notebook 会话：前端持有 sessionId，组件销毁时调用 stopNotebookSession 释放会话（`NotebookView.svelte:213-215`）。
- 长输出：stdout 超过 100 行后限高滚动，文件内容按需懒加载。本次未发现定时器、动画或 WebGL 的登记与暂停机制（本类目无相关对象）；多会话并发时共享 worker 用请求 id 匹配响应，同一个 worker 串行处理任务（`CodeBlock.svelte:605-608`、`src/lib/workers/pyodide.worker.ts:242-259`）。

## 11. 测试、已确认边界与未验证事项

- 测试资产：本快照 `test/` 仅有一个占位文件；前端唯一测试是版本对比工具 `src/lib/components/workspace/common/versionDiff.test.ts`。本次未找到针对代码解释器、Artifact、notebook、pyodide 文件系统、output 持久化恢复的自动化测试。
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
- 能力等级（横向对比口径，按输出深度分级）：**G3（可执行 Artifact：Pyodide/Jupyter 代码执行、HTML 沙箱预览、工具结果物化）为主体，部分 G4（代码块与 notebook 单元编辑保存、文件编辑回写，但无 diff/版本/接受拒绝）与部分 G5（模型可读写沙箱文件系统、同一输出项就地更新并回流，但仅会话级、无对象查询协议、默认不跨会话持久化）**。各轴单列：
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
