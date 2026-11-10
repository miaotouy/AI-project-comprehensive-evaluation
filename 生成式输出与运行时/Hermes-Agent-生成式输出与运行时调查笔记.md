# Hermes Agent 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/NousResearch/hermes-agent`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`71736c9f32597bbca9d89cede5aa136e55946b2f`（分支：`main`）
>
> 调查方式：静态代码阅读为主；grep/glob 检索 artifact、canvas、sandbox、iframe、webview、notebook、diff、patch、execution、preview、MEDIA 等关键词；重点阅读 `tools/code_execution_tool.py`、`tools/open_preview_tool.py`、`tools/read_preview_tool.py`、`tools/desktop_ui.py`、`apps/desktop/src/store/artifacts.ts`、`apps/desktop/src/store/preview.ts`、`apps/desktop/src/app/chat/right-rail/preview-*.tsx`、`tui_gateway/server.py`、`gateway/platforms/base.py` 等；未运行应用与测试
>
> 调查范围：模型输出获得独立对象身份或专用运行环境的完整链路（对象模型、预览与执行环境、持久化、模型回流）；CLI/TUI/Web 的普通 Markdown 渲染、消息时间线装配、审批/调度语义、git 操作细节属于相邻类目，仅记录交接点；未验证任何运行行为
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Hermes Agent 是 Python Agent 核心 + 多端表面（CLI/TUI/Web 仪表盘/Electron 桌面/约 20 个消息平台）的混合 monorepo。生成式输出没有统一的类型化对象协议，而是三种松散约定并行：`MEDIA:<path>` 纯文本标签（消息平台附件、桌面媒体附件）、Preview 形式的 Markdown 链接（旧链接约定）与 desktop_preview 工具的结构化打开/关闭事件、以及桌面渲染器对代码围栏的后验启发式"物化"（artifact card + 版本化注册表）。真正的持久对象是**文件**（模型用 write_file/patch/terminal 落盘、经 `MEDIA:` 或预览面展示），artifact 注册表只存在于桌面渲染器内存中、以聊天记录为事实源、不可被模型寻址。桌面端具备一个完整的主链：HTML/Python 代码围栏 → 流式检测 → artifact 卡片 → 右侧栏预览标签页（HTML 在 `iframe sandbox="allow-scripts"` 中运行、URL 在沙箱 webview 中运行）→ 版本切换/复制/下载/浏览器打开 → 会话恢复时从消息记录重建注册表。模型回流通道存在但不完整：预览读取与终端读取工具可读取桌面面板内容，文件读取工具回流磁盘文件，但 artifact 对象列表与版本不可被模型查询。无 notebook、无画布、无白板。能力等级定为 **G3**（桌面可执行 HTML Artifact + 沙箱预览 + 版本化持久展示），在"文件"这一对象类别上有部分 G4 特征（用户可在预览面板内就地编辑并保存、冲突检测、diff 视图、git 审查面板），但 artifact 对象本身不可用户编辑、模型也不可查询，未达 G5。

## 系统边界与完整主链路

**系统边界**：输出协议与对象模型由 Python 侧工具与桌面渲染器共同定义，但双方没有共享的 artifact schema。事实源是 SQLite 会话库（`hermes_state.py` 的 `SessionDB`，`~/.hermes/state.db`）；投影面有四类——消息平台（原生附件）、CLI/TUI（纯文本）、Web 仪表盘（嵌入真实 TUI 的 xterm 终端 + 管理页）、Electron 桌面（rich 消息 + 右侧栏预览标签页 + artifact 画廊页 + 文件/审查面板）。代码执行有两套互不相干的环境：`execute_code` 工具（模型在 Python 子进程中写脚本并 RPC 调用白名单工具，属于 Agent 工具类目）与桌面预览面板（用户查看生成 HTML/URL 的沙箱运行时）。

**主链（桌面，已由静态代码走通）**：

1. 触发：用户在客户端输入 prompt，入口是会话创建与提交两个 RPC（`tui_gateway/methods_session.py:14`）。
2. 生成：模型以 Markdown 流式输出，桌面渲染器对每个代码围栏的增量内容跑检测；检测函数只做正则与行数判定，每收到一个 delta 就运行一次，开销有界（`apps/desktop/src/lib/artifact-detect.ts:106`）。
3. 展示与运行：围栏收尾后该块注册为 artifact 并渲染成卡片，流式期间卡片显示 shimmer 与行数。用户点击卡片时，`openArtifact()` 在右侧栏新开预览标签页，HTML 以 `srcDoc` 注入 `sandbox="allow-scripts"` 的 iframe 实时运行，SVG 经 DOM 消毒后内联（`apps/desktop/src/store/artifacts.ts:190`、`preview-artifact.tsx:96-107`）。
4. 交互与编辑：标签页提供版本步进（同一 slug 的新内容自动追加版本，上限 20 版）、RENDERED/SOURCE 模式切换、复制、下载和系统浏览器打开。标签页只保存 artifact id，内容从注册表实时读取，所以已打开的面板会自动跟到最新版本（`preview-artifact.tsx:175-262`）。
5. 保存：用户下载单文件；模型也可以用 `write_file` 把同样内容写进工作区文件。
6. 重新打开：会话经 `session.list`/`session.resume` 恢复后，转写文本重新渲染，卡片组件随之重新注册 artifact，注册表与版本历史由此重建。注册表只在内存中保存，注释写明"memory-only, transcript is the durable copy"（`tui_gateway/methods_session.py:162,306`、`store/artifacts.ts:19-22`）。

**模型回流闭环（部分）**：模型可读取当前预览标签页正文（经阻塞桥）、终端内容与磁盘文件，历史经会话检索工具召回。定向修改：模型重新生成同名 HTML → 同一 slug 追加新版本，已打开的标签页自动更新；文件则用 `patch` 工具（增/删/移/改四类操作，`tools/patch_parser.py:39-61`）定向修改。本快照中"模型查询 artifact 列表并选择版本"的通道不存在。

## 1. 触发方式、输出协议与对象模型

**触发**：artifact 的创建没有用户显式命令，由桌面渲染器对模型自由文本中的代码围栏做后验检测，检测门槛与排除规则按围栏类型区分（`artifact-detect.ts:26-55`）：

| 围栏类型 | 规则 |
|---|---|
| html 文档 | ≥160 字符 |
| html 片段 | ≥1200 字符 |
| svg | ≥2000 字符 |
| 代码 | ≥3000 字符或 48 行 |
| diff、patch、mermaid、markdown、text | 一律排除 |

流式输出期间，检测函数在每个增量 delta 上重跑围栏内容；注册环节按内容哈希去重，所以流式重挂载与转写重渲染都是幂等的，卡片在流式结束前不会注册（`store/artifacts.ts:127-139`、`artifact-card.tsx:55-60`）。误触发由体积门槛、`isLikelyProseCodeBlock` 散文排除和语言黑名单共同拦截。

**输出协议（三层，均非类型化）**：

- `MEDIA:<absolute-path>`：由消息平台消费的纯文本媒体标记。工具端产出路径，平台提示词教会模型在回复里写出这个标记，消息平台把它拦截成原生附件；图像生成工具的成功结果还可通过本地路径字段进入自动补挂链。

  生产端覆盖 TTS、MCP 工具、视频生成与浏览器等工具，入口见下。提示词里直接给出示例串，例如 WhatsApp/Telegram 平台要求模型在回复中包含 `MEDIA:/absolute/path/to/file`（`agent/prompt_builder.py:793-830`）。

  自动补挂链只扫描本轮允许的生产工具结果，按媒体扩展名匹配路径；图像生成成功结果中的本地路径字段也可转成媒体标记，因此模型最终回复省略标记时仍可补入递送目标。提取与补挂见 [生产工具结果处理](<../../hermes-agent/gateway/run.py#L1434-L1491>)、[最终回复补挂入口](<../../hermes-agent/gateway/run_turn_runner.py#L1181-L1208>)。

  递送前先解析目标并确认它是现有普通文件，缓存或操作者白名单内直接放行；白名单外默认按拒绝表筛选，strict 模式还要求满足已启用的新鲜度窗口。分支顺序见 [路径准入](<../../hermes-agent/gateway/platforms/base.py#L1055-L1091>)，配置与拒绝表边界详见第 7 节。

  桌面端把同一个标记行改写成媒体链接再渲染为播放器（`apps/desktop/src/lib/chat-messages.ts:136-150`、`apps/desktop/src/lib/media.ts:57-59`）。
  - 生产端入口：`tools/tts_tool.py:3455,3663`、`tools/mcp_tool.py:915,967`、`tools/video_generation_tool.py`、`tools/browser_tool.py`
  - **媒体保真加固**：排队重发会保留受保护的 `MEDIA:` 标记与其后的跟进媒体，失败的首回合跳过附件上传但仍完成投递；容器到宿主机的媒体路径翻译扩展到 home、cache 与进程内网关；terminal 后端的读取统一走共享媒体解析器；draft 终态发送不再带 `expect_edits`。
  - **图像后处理**：图片生成后对小于 2MP 的产物默认追加一次 upscale，链路为 FAL Clarity Upscaler，是否执行由模型的 `upscale` 旗标决定（`tools/image_generation_tool.py:11-153`）。
- `#media:`/`#preview/` href 是消息链接消费约定。预览工具的实际入口是 desktop_preview：open/close 通过结构化的 `preview.open`/`preview.close` 事件驱动 UI，read 经 Agent 回调读取面板；该工具归在 desktop_ui 下，可用性由会话来源决定（[工具 schema 与注册](../../hermes-agent/tools/preview_tool.py#L26-L78)）。
- 打开请求经 URL/本地路径归一化后发出事件，拒绝目录；桌面只响应当前窗口屏幕上可见会话的请求，再按 owner/profile 路由预览，后台隐藏会话不会抢开面板（[生产端](../../hermes-agent/tools/open_preview_tool.py#L70-L89)、[消费端](../../hermes-agent/apps/desktop/src/app/session/hooks/use-preview-routing.ts#L97-L132)）。
- 工具结果统一是 JSON 字符串，没有结构化的 tool part 承载 artifact。桌面端用字段名正则 `KEY_HINT_RE` 从工具结果与转写里挖出文件路径和 URL，填进 "Artifacts" 画廊页（`app/artifacts/artifact-utils.ts:20-26,202-244`）。

**对象模型**：桌面 artifact 的稳定身份是 `(sessionId, slug)`，slug = `kind:language:title`（`artifact-detect.ts:159-167`）；记录含创建/更新时间、类型、语言、标题与版本数组，版本以 FNV-1a 内容哈希去重（`store/artifacts.ts:24-41,115-179`）。无"创建者"字段（creator 即会话），无状态机（只有版本序列），无能力声明。事实源层级：**聊天记录（state.db）> 渲染器内存注册表 > 预览标签页（只持引用）**。注册表限额：每会话 24 个、每 artifact 20 版本、共 40 会话，超限按 updatedAt 淘汰（`store/artifacts.ts:45-67`）。

## 2. 增量生成、更新与最终化

- 文本流：消息正文由 `StreamdownTextPrimitive` 流式渲染；artifact 检测直接跑在增量围栏体上，每个 delta 都会全量重扫当前围栏内容，算法本身是有界正则与行数判定（`markdown-text.tsx:598-615`）。
- 更新链：**整段替换 + 版本追加**。同一 slug 收到新内容时，旧版本保留、新内容另存为一个版本；已打开的标签页只记 artifact id，因此会自动跟到最新版（`store/artifacts.ts:181-199`）。artifact 内容上没有 AST 节点级 patch，也没有 diff 应用。
- 文件侧更新链：`write_file` 与 `patch` 直接改文件。工具启动时网关先快照文件，完成时生成 inline diff 并随工具完成事件推给桌面，桌面的 diff 面板据此呈现（`tui_gateway/server.py:5304,5352-5365`、`agent/display.py:1025`、`fallback.tsx:625-627`）。
- 最终化与失败：artifact 在围栏完成那一刻注册，注册时机由 `useEffect` 依赖的 `streaming` 标志决定；流式中途失败则只留下一个未注册的普通代码块，没有版本回滚概念。大工具输出另有独立的持久化层（见 §8）。

## 3. 投影表面与多视图关系

| 表面 | 内容 | 依据 |
|---|---|---|
| 桌面消息内 | `ArtifactCard`（流式 shimmer → 卡片）、`MEDIA:` 播放器、FileDiffPanel、Changed files 卡 | `artifact-card.tsx`、`chat-messages.ts`、`changed-files.ts` |
| 桌面右侧栏预览标签页 | 三类 target：`artifact`/`file`/`url`（`store/preview.ts:21-44`）；url 是单例 Browser 标签，file/artifact 按身份建标签；标签页经 `paneMirror` 镜像为布局树面板 | `store/preview.ts:190-227`、`preview-tile.tsx` |
| 桌面 Artifacts 画廊页 | 跨会话的文件/图片/链接列表（路径正则挖掘），可跳转会话 | `app/artifacts/index.tsx`、`artifact-utils.ts` |
| 桌面文件/审查面板 | 文件浏览、工作树 git diff + stage/revert/commit/PR（Electron git 桥） | `app/right-sidebar/review/`、`store/review.ts` |
| 消息平台 | 原生附件（照片/语音/文档） | `gateway/run.py`、`send_message_tool.py` |
| CLI/TUI/Web 仪表盘 | 纯文本与路径；TUI 把 `![alt](url)` 渲染为 `[image: name] url` 文本链接（`ui-tui/src/components/markdown.tsx:195`）；Web 仪表盘主体是嵌入的 TUI 终端 | `hermes_cli/pty_bridge.py`、`web/src/pages/ChatPage.tsx` |

多视图同步：一个 artifact 的注册表记录、标签页引用、消息内卡片是同一对象的三份视图，标签页/卡片都从注册表派生；文件视图（file 标签、画廊页、文件面板）各自独立读取磁盘，无缓存一致性协议（文件变化靠重新读取 + 事件刷新）。

## 4. 表现类型、依赖与运行环境

- **HTML artifact**：运行容器是 `sandbox="allow-scripts"` 的 iframe，页面正文经 `srcDoc` 注入。沙箱未开 allow-same-origin，文档因此处于不透明源：不能做顶层导航、弹出窗口或表单外发，父应用也访问不到它；画布强制为浅色。所有依赖都来自生成内容自身，不注入外部资源（`preview-artifact.tsx:82-108`）。
- **远程 HTML data URL**：远程网关模式下，桌面预览需要把文件内容搬进本地，走的是 data URL 通道。整份文档先经 DOMPurify 消毒，`script/template/iframe/object/embed` 这类可执行与嵌入标签一律移除，链接与动作属性一并清掉，再以 CSP `default-src 'none'; img-src data:; style-src 'unsafe-inline'` 限制资源加载，体积上限 16MB（`lib/local-preview.ts:83-145`）。
- **URL 标签页**：用 Electron `<webview>` 承载，分区固定为 `persist:hermes-preview`，开启 contextIsolation 与 sandbox、关闭 nodeIntegration；同时采集 console、提供 devtools、监听导航与加载事件，并注入脚本读取页面文本（`preview-pane.tsx:324-344,553-557`）。console 与 devtools 状态按标签页登记（`preview-strip-tools.tsx`）。
- **本地文件**：image、PDF（blob URL）与 text 各有渲染分支，另提供 Shiki 高亮的源码视图和工作树 diff 视图。本地 HTML 文件按源码展示，只有 artifact 里的 HTML 会真正执行（`preview-file.tsx:664-667`）。
- **SVG**：同样经 DOMPurify 处理，启用 svg 与 svgFilters 两个 profile。
- **语言解释器**：`execute_code` 工具跑在 Python 子进程里（§7），结果只以文本形式回给模型，用户无法直接操作该进程的产物。
- 能力上限：没有 Canvas/WebGL 专用运行时，没有 notebook（`.ipynb` 只能读取，`tools/read_extract.py`），也没有 draw.io/Excalidraw 画布。全仓检索未发现 notebook 运行时或画布类实现，`prompt_builder.py:949` 只是把 Excalidraw 文件当作可发送附件。

## 5. 用户交互、事件与错误反馈

- artifact 卡片是主要的打开入口：用户点击卡片，右侧栏就弹出对应的预览标签页。模型也可以通过 desktop_preview 的 open 动作请求预览，但请求只对所属窗口当前在屏的会话生效，后台隐藏会话发来的请求不会抢开面板（[消费门控](../../hermes-agent/apps/desktop/src/app/session/hooks/use-preview-routing.ts#L97-L132)）。
- artifact 标签页内：版本前后步进、跳最新、复制内容、下载文件、系统浏览器打开、RENDERED/SOURCE 切换（`preview-artifact.tsx:200-261`）。
- URL 标签页内：刷新、devtools、console、monitor（`preview-pane.tsx:289-307`）。前端服务挂掉时可用 `preview.restart` RPC：网关侧拉起一个专门的临时 agent 来修复，它只启用 terminal/file 工具集、跳过 memory、把最近 24 条消息蒸馏成上下文，进度经 `preview.restart.progress` 回传（`tui_gateway/server.py:5987-6110`）。
- 本地文件标签页内：按 `e` 进入就地编辑器，可保存；保存时若磁盘内容已变化会触发冲突检测并提供强制覆盖横幅，编辑器里同时标出修改点（`preview-file.tsx:793-908`）。
- 错误反馈：图片加载失败显示失败态并可重试；远程 HTML 不可读时降级为 source 视图并标记 `transient`（`local-preview.ts:234-241`）。
- 重载恢复：file 与 url 标签页写入 localStorage，恢复时校验合法性；artifact、transient、dataUrl 三类标签页不持久化，内存注册表重建后需要用户重新打开 artifact 标签页（`store/preview.ts:85-151`）。版本选择状态存在 `$artifactVersionSelection` 原子中，同样不持久化。

## 6. 编辑、diff、版本与协作

- **用户 ↔ artifact**：这一层没有编辑通道。用户能做的操作是查看、复制、下载和用浏览器打开；"迭代"能力全部落在模型侧，即模型重新生成一版、内容变成新版本。
- **用户 ↔ 文件**：预览面板支持就地编辑并保存，保存时如果磁盘已被改动会先做冲突检测，并给出强制覆盖入口（`preview-file.tsx:885-908`）。右侧栏的 review 面板面向工作树提供 stage/unstage/revert/commit/PR，由 Electron git 桥支撑，定位是提交前审查 agent 的改动（`store/review.ts`）。
- **模型 ↔ 文件**：`write_file` 做全文覆盖，`patch` 做增、删、移、改四类结构化编辑，两者都直接改盘（`patch_parser.py`）。系统里没有 CRDT；`session.branch` 是会话级的历史分支，与对象级版本无关（`methods_session.py:2672`）。
- **diff 呈现**：三个来源并列——编辑工具产生的 inline diff、文件标签页里的 working-tree-vs-HEAD diff、消息内的 Changed files 卡片（`agent/display.py`、`preview-file.tsx:716-730`、`changed-files-card.tsx`）。
- **协作冲突表达**：冲突面只有"用户保存时磁盘已是新状态"一种，没有接受/拒绝 UI，也没有撤销栈；`session.undo` 是消息级操作（`methods_session.py:2381`）。

## 7. 能力桥、执行位置与权限范围

- **`execute_code`（模型侧代码执行，Agent 工具类目）**：默认走按会话身份复用的持久 Python 内核，每次调用新建一次性解释器的旧做法已经取消。每个 cell 执行前重新绑定当前工具权限，变量、导入和助手函数留在会话里；子 Agent 以委派会话 ID 相互隔离。关闭会话、执行 `/new`、超时或中断都会销毁对应内核。远端 Docker、SSH、Modal 后端各有结构相同的 detached kernel 注册表（`tools/code_kernel.py:412-747`、`tools/code_kernel_remote.py:106-394`）。子进程环境仍会剥离 API 密钥，完整脚本要经过审批守卫。内核内可调用的白名单工具共 7 个：

  ```
  web_search, web_extract, read_file, write_file, search_files, patch, terminal
  ```

- **`terminal` 环境**：本地与远程后端统一实现在 `tools/environments/` 下。
  - 远程后端：Docker、SSH、Modal、Daytona、Vercel
  - 插件后端：Singularity、Apptainer
- **桌面预览运行时**：webview/iframe 均为沙箱，无网络桥（HTML artifact 内脚本不能请求外部资源也不会被宿主响应）。
- **桌面宿主桥**（`window.hermesDesktop`）：暴露给渲染器的一组类型化窄接口，覆盖以下能力：
  - 文件读写，例如 `readDesktopFileDataUrl`（`lib/desktop-fs.ts`）
  - git 操作
  - `hermes-media://` 流媒体协议
  - 保存图像、打开浏览器、预览目标归一化（`lib/local-preview.ts:147-179`、`lib/media.ts:122-127`）
- **read_window_below**（`tools/read_window_tool.py`）：桌面能力桥工具，用来询问宿主"Hermes 窗口正下方是哪个 OS 窗口"。请求经 `window.read.request/respond` 阻塞桥发出，回传序列化后的窗口元数据，超时 30 秒，回调入口为 `read_window_below_callback`；Windows 侧靠 Electron 主进程的 get-windows 原生绑定完成枚举。这项能力分三步落地：先引入工具，再补上 Windows 原生窗口枚举，最后让桌面对应答失败给出原因（`tui_gateway/server.py:5870-5879`）。
- 它与 `read_preview`、`read_terminal` 同属"模型查询桌面环境"的能力桥族。
- **网关媒体递送权限**：先解析路径与符号链接并确认目标为现有普通文件，再按白名单和递送模式判断。白名单与新鲜度是不同的放行来源，判断顺序如下（[路径校验](<../../hermes-agent/gateway/platforms/base.py#L1055-L1091>)）：

  | 条件 | 行为 |
  |---|---|
  | 命中缓存或操作者配置的白名单根目录 | 直接放行，两个模式均适用，无需再检查新鲜度 |
  | 白名单外，默认非 strict 模式 | 文件位于拒绝表之外即可放行 |
  | 白名单外，strict 模式 | 文件须在拒绝表之外，且满足已启用的新鲜度窗口；窗口默认 10 分钟，可配置或关闭 |

  缓存白名单包括 Hermes 缓存目录中的图片、音频、视频、文档和截图；操作者还可配置额外根目录。拒绝表用于后两条分支，覆盖系统路径与用户凭据目录；缓存等白名单优先于拒绝表判断，运行用户自身的 home 根目录另有例外（[白名单与窗口配置](<../../hermes-agent/gateway/platforms/base.py#L735-L864>)、[拒绝表判断](<../../hermes-agent/gateway/platforms/base.py#L873-L904>)）。

  `/api/files/download` 的下载请求另走 Web 鉴权；回环模式也接受查询参数 token，便于从浏览器外部打开链接（[下载入口](<../../hermes-agent/hermes_cli/web_routers/files.py#L813-L830>)、[查询 token 校验](<../../hermes-agent/hermes_cli/web_server.py#L311-L325>)）。

## 8. 持久化、恢复、分享与导出

- 事实源是 `SessionDB`，即带 FTS5 会话检索的 SQLite 库（`hermes_state.py:1890`）。artifact 注册表刻意不落盘，注释写明"transcript is the durable copy"，重载时由卡片重新注册重建（`store/artifacts.ts:19-22`）。
- 预览标签页只有 file 与 url 两类会持久化到 localStorage 的 `hermes.desktop.previewTabs.v2`：dataUrl 字段被剥离，artifact、transient 和 HTML-dataUrl 行在写入前被过滤（`store/preview.ts:137-151`）。
- 大工具结果超过阈值时落盘到 `<tmp>/hermes-results/{tool_use_id}.txt`，上下文里换成一段预览加路径，模型可用 `read_file` 取回（`tools/tool_result_storage.py:1-23`）。
- `execute_code` 另有输出溢写：stdout/stderr 超过内联预算就写入结果文件并返回可继续读取的路径，避免持久内核把一次大输出整段塞回对话上下文（`tools/code_execution_tool.py:58,83-93,742`）。
- 导出有三条路径：artifact 单文件下载（扩展名按语言决定）、把 HTML 写成临时文件后交给系统浏览器、远程文件经 `/api/files/download` 下载（`artifact-detect.ts:181-231`、`preview-artifact.tsx:49-72`、`lib/media.ts:170-187`）。目前没有分享链接，也没有对象级的迁移或删除版本入口。

## 9. 模型回流、对象感知与持续维护

- 可查询：
  - `desktop_preview(action="read")`：读取当前预览标签页的正文。底层仍走 read_preview 回调；目标是文件标签页时只返回身份信息，并提示改读磁盘文件（[统一工具入口](../../hermes-agent/tools/preview_tool.py#L43-L68)）。
  - `read_terminal` 与 `read_file`：分别读取终端输出和任何已写出的文件。
  - `session_search`：跨会话检索历史转写（`tools/session_search_tool.py`）。
  - desktop_preview 的 open/close 动作：控制当前会话拥有的投影面。
  - `read_window_below`：读取桌面下方 OS 窗口的元数据（见 §7）。
  - `vision_analyze` 的区域缩放：按 `region=[x1,y1,x2,y2]` 在原图像素坐标上裁剪并放大细节后再分析，实现函数为 `_crop_image_region`，方案源自 Qwen 的 zoom-image（`tools/vision_tools.py:681`）。
- 不可查询：artifact 注册表对模型完全不可见，没有列出 artifact、读取版本源码或选择版本的模型侧通道。模型想读回自己生成的 HTML，只能靠 `read_preview`（前提是该 artifact 正开在预览面板里）或磁盘文件（前提是曾经落盘）。
- 持续维护：同一会话内重新生成会让同一 slug 追加版本，已打开的标签页自动跟进，这是"持续维护"的最强形式，而且整个过程无需模型感知——注册表由渲染器自动维护，模型并不知道自己在产生"版本"。跨会话没有对象身份延续：slug 不含会话外身份，重开会话就是一张新注册表。

## 10. 生命周期、资源治理与性能

- 注册表淘汰：每个会话最多保留 24 个 artifact，每个 artifact 最多 20 个版本，同时跟踪的会话上限 40 个，超限按 updatedAt 淘汰（`store/artifacts.ts:45-67`）。
- 标签页：file 与 url 标签跨会话存活，只在用户主动关闭时消失；artifact 标签在注册表清空时由 `closeArtifactPreviewTabs` 一并关闭（`store/preview.ts:265-271`）。webview 仅在 URL 标签存在时挂载，关闭时调用 `webview.remove()` 卸载；console 与 devtools 状态按标签懒创建并缓存（`preview-pane.tsx:639-647`、`preview-strip-tools.tsx:11-13`）。
- 执行资源：`execute_code` 超时或硬中断会杀死内核并报告状态丢失；本地与远端内核都按会话回收。终端后台进程与浏览器 daemon 同样在会话收尾时关闭（`tools/code_kernel.py:709-747`、`gateway/run.py:9622`、`gateway/slash_commands.py:137`）。
- 性能手段：artifact 检测是纯函数，按 delta 增量调用但结果有界；卡片靠哈希去重只注册一次；`AssistantMessage` 用稳定选择子，避免流式过程中重渲染整棵消息树（`assistant-message.tsx:60-96`）。

## 11. 测试、已确认边界与未验证事项

当前提交未引入统一的 artifact 数据契约或新的画布/笔记本运行时。桌面端仍从消息记录重建代码围栏 artifact；本轮浏览器与会话基础设施变化不应被外推为生成式输出对象模型已经类型化。

**测试覆盖（静态确认存在）**：

| 测试文件 | 覆盖内容 |
|---|---|
| `apps/desktop/src/lib/artifact-detect.test.ts` | 检测门槛、标题、排除表 |
| `store/artifacts.test.ts` | 版本去重与版本选择 |
| `app/artifacts/index.test.ts` | 画廊收集 |
| `preview-targets.test.ts` | — |
| `preview-pane.test.tsx` | webview 挂载与失败分支 |
| `preview-artifact.test.tsx` | — |
| `preview-reader.test.ts` | — |
| `preview-open.test.tsx` | `preview.open` 事件路由 |

Python 侧没有 artifact 协议测试（该概念不存于 Python）。

E2E（`apps/desktop/e2e/`）覆盖启动/聊天/会话/右侧面板，未发现专门走"围栏 → artifact 卡片 → 预览 → 版本 → 恢复"整链的用例。

**已确认边界**：
- artifact 是渲染器侧的启发式对象，没有协议约定，模型无法寻址，用户也无法编辑（源码确认，见 `store/artifacts.ts` 注释）。
- 旧的 Markdown Preview href 辅助函数本次未找到生产侧调用者；模型主动打开、关闭和读取预览走的是 desktop_preview 的工具事件与回调链（§1）。这两个入口要分开判断。
- 本地 HTML 文件只显示源码，artifact 中的 HTML 才会执行（`preview-file.tsx:664-667`）。
- notebook、画布与白板都没有专用运行时。检索范围是全仓 `*.py`/`*.ts`/`*.tsx` 内的 jupyter、notebook、draw.io、excalidraw、whiteboard，已排除 node_modules、网站与技能目录，只发现 `.ipynb` 读取以及图标和文档中的提及。

**未验证事项**（本次未运行）：
- 流式检测到卡片落定的实际时序，以及组件重挂载时的行为；
- webview 与 iframe 沙箱在真实 Electron 里的隔离强度，以及 console 采集的实际表现；
- `read_preview` 桥在远程网关模式下的端到端延迟与超时表现；
- 版本注册表在会话压缩、恢复、分支之后能否正确重建，这一点取决于 `session.resume` 的转写完整度；
- 消息平台 `MEDIA:` 递送的视觉形态，属于相邻类目，未深查；
- 持久内核的跨多轮状态、远端心跳恢复、输出溢写与子 Agent 隔离，均未做运行验证；
- 按路径复核了 artifact/预览模块与桌面右栏的归位（含 `chat-messages` 目录化），26k 提交范围内的渲染实现未逐行重读；新增的桌面 `agents`、`learning`、`pet-generate` 等表面不在本笔记主链内，未展开。

## 12. 关键源码索引

- `apps/desktop/src/lib/artifact-detect.ts`：围栏 → artifact 检测、slug、哈希、下载名
- `apps/desktop/src/store/artifacts.ts`：内存注册表、版本追加、淘汰
- `apps/desktop/src/store/preview.ts`：预览标签页模型与持久化策略
- `apps/desktop/src/app/chat/right-rail/preview-artifact.tsx`：artifact 沙箱 iframe 与版本 UI
- `apps/desktop/src/app/chat/right-rail/preview-pane.tsx`：URL webview 沙箱与 console/devtools
- `apps/desktop/src/app/chat/right-rail/preview-file.tsx`：文件渲染/diff/就地编辑与冲突
- `apps/desktop/src/lib/preview-targets.ts`、`lib/media.ts`、`lib/chat-messages/`：`#preview/`、`#media:`、`MEDIA:` 三协议消费端（chat-messages 已拆为目录，含 codex sidecar/interim preservation 等专门测试）
- `apps/desktop/src/app/artifacts/artifact-utils.ts`：跨会话画廊挖掘
- `tools/open_preview_tool.py`、`tools/read_preview_tool.py`、`tools/focus_pane_tool.py`、`tools/desktop_ui.py`、`tools/read_window_tool.py`：桌面能力桥工具
- `tools/code_execution_tool.py`：模型侧 Python 沙箱（UDS/TCP RPC、白名单、审批）
- `tools/patch_parser.py`：v4a 结构化文件编辑
- `tools/tool_result_storage.py`：大结果落盘回读
- `agent/prompt_builder.py:793-830`：`MEDIA:` 协议的平台提示词
- `gateway/run.py:1550-1693`、`gateway/platforms/base.py:1180-1240`：媒体递送与权限
- `tui_gateway/server.py`：编辑快照与 inline diff 事件、预览重启临时 agent、`window.read.request` 桥（5870-5879）
- `hermes_state.py`、`tui_gateway/methods_session.py`：会话持久化与恢复
