# Hermes Agent 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/NousResearch/hermes-agent`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`791e2ae3257e211d14ca77e654dfe10ee1976a1c`（分支：`main`）
>
> 调查方式：静态代码阅读为主；grep/glob 检索 artifact、canvas、sandbox、iframe、webview、notebook、diff、patch、execution、preview、MEDIA 等关键词；重点阅读 `tools/code_execution_tool.py`、`tools/open_preview_tool.py`、`tools/read_preview_tool.py`、`tools/desktop_ui.py`、`apps/desktop/src/store/artifacts.ts`、`apps/desktop/src/store/preview.ts`、`apps/desktop/src/app/chat/right-rail/preview-*.tsx`、`tui_gateway/server.py`、`gateway/platforms/base.py` 等；未运行应用与测试
>
> 调查范围：模型输出获得独立对象身份或专用运行环境的完整链路（对象模型、预览与执行环境、持久化、模型回流）；CLI/TUI/Web 的普通 Markdown 渲染、消息时间线装配、审批/调度语义、git 操作细节属于相邻类目，仅记录交接点；未验证任何运行行为
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Hermes Agent 是 Python Agent 核心 + 多端表面（CLI/TUI/Web 仪表盘/Electron 桌面/约 20 个消息平台）的混合 monorepo。生成式输出没有统一的类型化对象协议，而是三种松散约定并行：`MEDIA:<path>` 纯文本标签（消息平台附件、桌面媒体附件）、Preview 形式的 Markdown 链接（桌面预览目标，本快照中只有解析端、没有生产端）、以及桌面渲染器对代码围栏的后验启发式"物化"（artifact card + 版本化注册表）。真正的持久对象是**文件**（模型用 write_file/patch/terminal 落盘、经 `MEDIA:` 或预览面展示），artifact 注册表只存在于桌面渲染器内存中、以聊天记录为事实源、不可被模型寻址。桌面端具备一个完整的主链：HTML/Python 代码围栏 → 流式检测 → artifact 卡片 → 右侧栏预览标签页（HTML 在 `iframe sandbox="allow-scripts"` 中运行、URL 在沙箱 webview 中运行）→ 版本切换/复制/下载/浏览器打开 → 会话恢复时从消息记录重建注册表。模型回流通道存在但不完整：预览读取与终端读取工具可读取桌面面板内容，文件读取工具回流磁盘文件，但 artifact 对象列表与版本不可被模型查询。无 notebook、无画布、无白板。能力等级定为 **G3**（桌面可执行 HTML Artifact + 沙箱预览 + 版本化持久展示），在"文件"这一对象类别上有部分 G4 特征（用户可在预览面板内就地编辑并保存、冲突检测、diff 视图、git 审查面板），但 artifact 对象本身不可用户编辑、模型也不可查询，未达 G5。

## 系统边界与完整主链路

**系统边界**：输出协议与对象模型由 Python 侧工具与桌面渲染器共同定义，但双方没有共享的 artifact schema。事实源是 SQLite 会话库（`hermes_state.py` 的 `SessionDB`，`~/.hermes/state.db`）；投影面有四类——消息平台（原生附件）、CLI/TUI（纯文本）、Web 仪表盘（嵌入真实 TUI 的 xterm 终端 + 管理页）、Electron 桌面（rich 消息 + 右侧栏预览标签页 + artifact 画廊页 + 文件/审查面板）。代码执行有两套互不相干的环境：`execute_code` 工具（模型在 Python 子进程中写脚本并 RPC 调用白名单工具，属于 Agent 工具类目）与桌面预览面板（用户查看生成 HTML/URL 的沙箱运行时）。

**主链（桌面，已由静态代码走通）**：

1. 触发：用户输入 prompt（`session.create`/`prompt.submit`，`tui_gateway/methods_session.py:14`）。
2. 生成：模型流式输出 Markdown；桌面渲染器对每个代码围栏的增量内容执行检测（`detectArtifact()`，`apps/desktop/src/lib/artifact-detect.ts:106`，纯正则/行数判定、每次流式 delta 运行、有界）。
3. 展示/运行：围栏收尾后注册为 artifact 并渲染成卡片（`artifact-card.tsx:41`），流式期间显示 shimmer + 行数；点击卡片经 `openArtifact()`（`apps/desktop/src/store/artifacts.ts:190`）打开右侧栏标签页，HTML 在 `<iframe sandbox="allow-scripts" srcDoc=…>` 中实时运行（`preview-artifact.tsx:96-107`），SVG 经 DOM 消毒后内联。
4. 交互/编辑：版本步进器（同 slug 新内容自动追加版本，最多 20 版）、RENDERED/SOURCE 模式切换、复制、下载、系统浏览器打开（`preview-artifact.tsx:175-262`）；打开的标签页跟随新版本（标签页只持 artifact id，内容从注册表实时读取）。
5. 保存：用户下载单文件；或模型本身已用 `write_file` 把同样内容写到工作区文件。
6. 重新打开：`session.list`/`session.resume`（`tui_gateway/methods_session.py:162,306`）恢复会话，转写文本重渲染时卡片组件重新注册 artifact，注册表与版本历史免费重建（`store/artifacts.ts:19-22` 注释明示"memory-only, transcript is the durable copy"）。

**模型回流闭环（部分）**：模型可读取当前预览标签页正文（经阻塞桥）、终端内容与磁盘文件，历史经会话检索工具召回。定向修改：模型重新生成同名 HTML → 同一 slug 追加新版本，已打开的标签页自动更新；文件则用 `patch` 工具（增/删/移/改四类操作，`tools/patch_parser.py:39-61`）定向修改。本快照中"模型查询 artifact 列表并选择版本"的通道不存在。

## 1. 触发方式、输出协议与对象模型

**触发**：无用户显式命令触发对象创建。artifact 由桌面渲染器对模型自由文本中的代码围栏做后验检测，四类门槛为（`artifact-detect.ts:26-55`）：
- html 文档 ≥160 字符、html 片段 ≥1200 字符、svg ≥2000 字符、代码 ≥3000 字符或 48 行；
- `diff`/`patch`/`mermaid`/`markdown`/`text` 等语言被排除。
半截流处理：检测函数在每次增量 delta 上重跑，但注册以内容哈希去重（`store/artifacts.ts:127-139`），流式重挂载与转写重渲染均为幂等；卡片在流式结束前不注册（`artifact-card.tsx:55-60`）。误触发防护：体积门槛 + `isLikelyProseCodeBlock` 散文排除 + 语言黑名单。

**输出协议（三层，均非类型化）**：

- `MEDIA:<absolute-path>`：唯一由"模型/工具 → 平台"单向消费的协议。工具端生产（TTS、MCP 工具、视频生成、浏览器等工具，生产端入口见下）；平台提示词教会模型在回复中输出（`agent/prompt_builder.py:793-830`，如 WhatsApp/Telegram 平台提示"include MEDIA:/absolute/path/to/file in your response"）；消息平台拦截为原生附件（`gateway/run.py:1550-1693`：扩展锚定的媒体标记匹配器只递送带可递送扩展名的真实路径——裸 prose 中的示例串永不递送，图像生成等工具的本地文件路径字段被提取为递送目标）；递送前有安全根校验（`gateway/platforms/base.py:1180-1240`）：缓存根白名单 + 10 分钟新鲜度信任 + 系统路径/凭据子路径硬拒；桌面渲染器把该标记行改写成媒体链接再渲染为播放器（`apps/desktop/src/lib/chat-messages.ts:136-150`、`apps/desktop/src/lib/media.ts:57-59`）。
  - 生产端入口：`tools/tts_tool.py:3455/3663`、`tools/mcp_tool.py:915/967`、`tools/video_generation_tool.py`、`tools/browser_tool.py`
  - **媒体保真加固**（相关提交，均属本协议演进）：
    - queued resend 保留受保护的 `MEDIA:` 标记与后续跟进媒体（`1648ab3a`、`808c8570`、`a52dd17d`、`0b17b691`，失败首回合跳过附件上传但保持投递）；
    - 容器→宿主媒体路径翻译扩展到 home/cache/进程内网关（`238351a6`、`a7dd8854`、`fe54ab4f`）；
    - terminal-backend 的读取统一经共享媒体解析器（`f2e936da`、`9eb3ac50`）；
    - draft 终态发送不再带 `expect_edits`（`0f227271`）。
  - **图像后处理**：图片生成后新增 sub-2MP 默认 upscale（FAL Clarity Upscaler 链，`66ea4e68`、`137960c9`，`tools/image_generation_tool.py:11-153`，按模型 `upscale` 旗标门控）。
- `#media:`/`#preview/` Markdown href：桌面渲染器在 Markdown 链接层消费，经链接组件分发（`markdown-text.tsx:252-269`）。注意 `previewMarkdownHref()`（`preview-targets.ts:27`）在本快照中没有生产侧调用者——Preview 协议的写入端缺失，仅解析端存活（`assistant-message.tsx:84-94` 从收尾文本提取主要预览目标）。
- 无结构化 tool part 承载 artifact。工具结果就是 JSON 字符串，桌面端用字段名正则（`KEY_HINT_RE`）从工具结果与转写中挖出文件路径/URL 填入"Artifacts"画廊页（`app/artifacts/artifact-utils.ts:20-26,202-244`）。

**对象模型**：桌面 artifact 的稳定身份是 `(sessionId, slug)`，slug = `kind:language:title`（`artifact-detect.ts:159-167`）；记录含创建/更新时间、类型、语言、标题与版本数组，版本以 FNV-1a 内容哈希去重（`store/artifacts.ts:24-41,115-179`）。无"创建者"字段（creator 即会话），无状态机（只有版本序列），无能力声明。事实源层级：**聊天记录（state.db）> 渲染器内存注册表 > 预览标签页（只持引用）**。注册表限额：每会话 24 个、每 artifact 20 版本、共 40 会话，超限按 updatedAt 淘汰（`store/artifacts.ts:45-67`）。

## 2. 增量生成、更新与最终化

- 文本流：`StreamdownTextPrimitive` 流式渲染（`markdown-text.tsx:598-615`），artifact 检测在增量围栏体上跑（每次 delta 全量重扫围栏内容，但算法为有界正则/行数）。
- 更新链：**整段替换 + 版本追加**。同一 slug 的新内容追加为新版本而非原地更新；已打开的标签页因只存 artifact id 而自动跟随最新版（`store/artifacts.ts:181-199`）。没有 AST 节点级 patch、没有 diff 应用在 artifact 内容上。
- 文件侧更新链：`write_file`/`patch` 直接改文件；`tui_gateway/server.py:5304` 在工具启动时快照文件，完成时经 `agent/display.py:1025` 生成 inline diff，随工具完成事件推给桌面（`server.py:5352-5365`），桌面以 diff 面板呈现（`fallback.tsx:625-627`）。
- 最终化/失败：artifact 在"围栏完成"瞬间注册（`useEffect` 依赖 `streaming` 标志）；流式失败只留下未注册的普通代码块，无版本回滚概念。大工具输出有独立持久化层（见 §8）。

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

- **HTML artifact**：`<iframe sandbox="allow-scripts">` + `srcDoc`（无 allow-same-origin → 不透明源，无顶层导航/弹窗/表单外发，父应用不可达），强制浅色画布（`preview-artifact.tsx:82-108`）。依赖全部来自生成内容自身，不注入外部资源。
- **远程 HTML data URL**（远程网关模式下把文件内容搬进桌面预览）：DOMPurify 全文档消毒 + 移除可执行与嵌入标签（script/template/iframe/object/embed）+ 去除链接与动作属性 + CSP `default-src 'none'; img-src data:; style-src 'unsafe-inline'` + 16MB 上限（`lib/local-preview.ts:83-145`）。
- **URL 标签页**：Electron `<webview>`，专属分区 `partition=persist:hermes-preview`，`contextIsolation=yes,nodeIntegration=no,sandbox=yes`（`preview-pane.tsx:553-557`）；附 console 采集、devtools、导航/加载事件与脚本注入读页面文本（`preview-pane.tsx:324-344`）。console/devtools 按标签页登记（`preview-strip-tools.tsx`）。
- **本地文件**：image/PDF（blob URL）/text 渲染 + 源码（Shiki 高亮）+ 工作树 diff 视图；本地 HTML 文件按源码渲染而非运行（`preview-file.tsx:664-667`）——与 artifact HTML（可运行）形成有意反差。
- **SVG**：DOMPurify `USE_PROFILES: {svg:true, svgFilters:true}`。
- **语言解释器**：`execute_code` 工具在 Python 子进程中运行（§7），其结果只回文本给模型，用户不可直接操作该进程的产物。
- 不支持层级：无 Canvas/WebGL 专用运行时、无 notebook（`.ipynb` 仅可读，`tools/read_extract.py`）、无 draw.io/Excalidraw 画布（全仓未检索到 notebook 运行时或画布类实现；`prompt_builder.py:949` 仅把 Excalidraw 文件当作可发送附件）。

## 5. 用户交互、事件与错误反馈

- 打开预览是**用户点击驱动**的硬约束："a background stream never steals the pane"（`artifact-card.tsx:37-39`）；agent 侧 `open_preview` 工具只对"在屏会话"生效且路由到所属窗口（`desktop_ui.py:32-40` 经 `HERMES_UI_SESSION_ID` 路由，`use-preview-routing.ts:60-93`）。
- artifact 标签页内：版本前后步进、跳最新、复制内容、下载文件、系统浏览器打开、RENDERED/SOURCE 切换（`preview-artifact.tsx:200-261`）。
- URL 标签页内：刷新、devtools、console、monitor（`preview-pane.tsx:289-307`）；`preview.restart` RPC 在网关侧拉起一个"临时预览重启 agent"（只启用 terminal/file 工具集、跳过 memory、蒸馏最近 24 条消息为上下文，`tui_gateway/server.py:5987-6110`）来修复挂了的前端服务，进度经 `preview.restart.progress` 回传。
- 本地文件标签页内：就地编辑器（`e` 键进入）、保存、磁盘内容变化冲突检测 + 强制覆盖横幅、修改点指示（`preview-file.tsx:793-908`）。
- 错误反馈：图片加载失败显示失败态并可重试；远程 HTML 不可读时降级为 source 视图并标记 `transient`（`local-preview.ts:234-241`）。
- 重载恢复：file/url 标签页持久化于 localStorage 并在恢复时校验合法性（`store/preview.ts:85-151`）；artifact/transient/dataUrl 标签页明确不持久化（内存注册表重建后 artifact 标签页由用户重新打开）。交互状态（版本选择）存于 `$artifactVersionSelection` 原子，不持久化。

## 6. 编辑、diff、版本与协作

- **用户 ↔ artifact**：无编辑通道——用户只能查看、复制、下载、浏览器打开；"迭代"能力只在模型侧（重新生成 → 新版本）。
- **用户 ↔ 文件**：预览面板就地编辑 + 保存，带"保存时磁盘已被改动"冲突检测与强制覆盖（`preview-file.tsx:885-908`）；`app/right-sidebar/review/` 面板对工作树提供 stage/unstage/revert/commit/PR（`store/review.ts`，Electron git 桥），定位为"提交前审查 agent 的改动"。
- **模型 ↔ 文件**：`write_file` 全文覆盖 + `patch` 结构化操作（增/删/移/改四类，`patch_parser.py`）直接改盘。无 CRDT；会话级 `session.branch`（`methods_session.py:2672`）是历史分支，不属于对象级版本。
- **diff 呈现**：编辑工具的 inline diff（`agent/display.py`）+ 文件标签页的 working-tree-vs-HEAD diff（`preview-file.tsx:716-730`）+ Changed files 卡片（`changed-files-card.tsx`）。
- **协作冲突表达**：只有"用户保存 vs 磁盘新状态"一个冲突面，无接受/拒绝 UI，无撤销栈（`session.undo` 是消息级操作，`methods_session.py:2381`）。

## 7. 能力桥、执行位置与权限范围

- **`execute_code`（模型侧代码执行，Agent 工具类目）**：本地路径为 Unix 域套接字/TCP RPC 的子进程（`code_execution_tool.py:1397-1416`），子进程环境剥离 API 密钥（`_scrub_child_env`，1441 起），超时 300s、工具调用 ≤50、stdout 50KB（74-77 行），完整脚本经审批守卫（`check_execute_code_guard`，1307-1318）；远程后端走文件型 RPC 进入 Docker/SSH/Modal/Daytona（16-29 行）；project/strict 两模式（`_get_execution_mode`，1809 行）。白名单工具 7 个（63-71 行）：
  - `web_search`、`web_extract`、`read_file`、`write_file`、`search_files`、`patch`、`terminal`
- **`terminal` 环境**：本地与远程后端（Docker/SSH/Modal/Daytona/Singularity/Vercel，`tools/environments/`）。
- **桌面预览运行时**：webview/iframe 均为沙箱，无网络桥（HTML artifact 内脚本不能请求外部资源也不会被宿主响应）。
- **桌面宿主桥**（`window.hermesDesktop`）：类型化窄桥——文件读写（`readDesktopFileDataUrl` 等，`lib/desktop-fs.ts`）、git、`hermes-media://` 流媒体协议、保存图像/浏览器打开/预览目标归一化（`lib/local-preview.ts:147-179`、`lib/media.ts:122-127`）。
- **read_window_below**（`tools/read_window_tool.py`）：桌面能力桥工具——询问宿主"Hermes 窗口正下方是哪个 OS 窗口"，经 `window.read.request/respond` 阻塞桥回传序列化窗口元数据（`server.py:5870-5879` `read_window_below_callback`，30s 超时）；Windows 侧经 Electron 主进程的 get-windows 原生绑定枚举。能力演进提交：
  - `406501fd`：引入该工具
  - `f22ae729`、`f463a7e8`、`2cd9e177`：Windows 原生窗口枚举
  - `04afc8d4`：桌面对应答失败给出原因
- 与 `read_preview`/`read_terminal` 同属"模型查询桌面环境"的能力桥族。
- **网关媒体递送权限**：缓存根目录白名单（`~/.hermes/cache/{images,audio,videos,documents,screenshots}` 等）+ 10 分钟新鲜度信任 + `/etc`、`/root` 等系统路径与 `$HOME` 下凭据目录硬拒（`gateway/platforms/base.py:1180-1240`）；`/api/files/download` 带查询 token 鉴权。

## 8. 持久化、恢复、分享与导出

- 事实源：`SessionDB`（SQLite + FTS5 会话检索，`hermes_state.py:1890`）；artifact 注册表**刻意不持久化**（"transcript is the durable copy"，`store/artifacts.ts:19-22`），重载时由卡片重新注册重建。
- 预览标签页持久化：localStorage `hermes.desktop.previewTabs.v2`，仅 file/url 行，dataUrl 剥离、artifact/transient/HTML-dataUrl 行过滤（`store/preview.ts:137-151`）。
- 大工具结果：超阈值结果落盘 `<tmp>/hermes-results/{tool_use_id}.txt`，上下文内换成预览 + 路径，模型 `read_file` 可取回（`tools/tool_result_storage.py:1-23`）。
- 导出：artifact 单文件下载（按语言定扩展名，`artifact-detect.ts:181-231`）、HTML 写临时文件后交给系统浏览器（`preview-artifact.tsx:49-72`）、远程文件经 `/api/files/download` 下载（`lib/media.ts:170-187`）。无分享链接、无对象级迁移/版本删除 UI。

## 9. 模型回流、对象感知与持续维护

- 可查询：
  - `read_preview`：当前预览标签页正文（`tools/read_preview_tool.py`，返回 `{kind,url,title,text,…}`，file 标签只回身份、"artifact tab points back at the conversation"）；
  - `read_terminal`、`read_file`：终端输出与任何已写文件；
  - `session_search`：跨会话检索转写（`tools/session_search_tool.py`）；
  - `open_preview`/`focus_pane`：投影面控制；
  - **`read_window_below`**：桌面下方 OS 窗口元数据（见 §7）；
  - **`vision_analyze` 区域缩放**：`_crop_image_region`（`tools/vision_tools.py:681`，`e166159f`）按 `region=[x1,y1,x2,y2]` 在原图像素坐标上裁剪放大细节再分析，源自 Qwen 的 zoom-image 方案。
- 不可查询：artifact 注册表对模型完全不可见——没有列出 artifact、读取版本源码、选择版本的模型侧通道。模型对"自己生成的 HTML"的唯一读回途径是 `read_preview`（若该 artifact 恰好开在预览面板里）或磁盘文件（若曾落盘）。
- 持续维护：同一会话内模型重新生成 → 同 slug 追加版本 → 已开标签页自动跟进（这是"持续维护"的最强形式，但**无需模型感知**——注册表由渲染器自动维护，模型并不知道自己在产生"版本"）；跨会话无对象身份延续（slug 不含会话外身份，重开会话即新注册表）。

## 10. 生命周期、资源治理与性能

- 注册表淘汰：24 个/会话、20 版本/artifact、40 会话（`store/artifacts.ts:45-67`）。
- 标签页：file/url 标签跨会话存活（"tabs close when you close them"）；artifact 标签在注册表清空时被关闭（`closeArtifactPreviewTabs`，`store/preview.ts:265-271`）；webview 仅在 URL 标签存在时挂载，`webview.remove()` 卸载（`preview-pane.tsx:639-647`），console/devtools 状态按标签 lazily 创建并缓存（`preview-strip-tools.tsx:11-13`）。
- 执行资源：`execute_code` 超时/上限/临时目录 `hermes_sandbox_*`；终端后台进程与浏览器 daemon 在会话收尾时关闭（`gateway/run.py:9622`、`gateway/slash_commands.py:137`）。
- 性能手段：artifact 检测纯函数、delta 增量调用但结果有界；卡片只注册一次（哈希去重）；`AssistantMessage` 通过稳定选择子避免流式重渲染整棵消息树（`assistant-message.tsx:60-96`）。

## 11. 测试、已确认边界与未验证事项

当前提交未引入统一的 artifact 数据契约或新的画布/笔记本运行时。桌面端仍从消息记录重建代码围栏 artifact；本轮浏览器与会话基础设施变化不应被外推为生成式输出对象模型已经类型化。

**测试覆盖（静态确认存在）**：
- `apps/desktop/src/lib/artifact-detect.test.ts`：检测门槛/标题/排除表
- `store/artifacts.test.ts`：版本去重/选择
- `app/artifacts/index.test.ts`：画廊收集
- `preview-targets.test.ts`
- `preview-pane.test.tsx`：webview 挂载/失败分支
- `preview-artifact.test.tsx`
- `preview-reader.test.ts`
- `preview-open.test.tsx`：`preview.open` 事件路由
- Python 侧无 artifact 协议测试（该概念不存于 Python）。

E2E（`apps/desktop/e2e/`）覆盖启动/聊天/会话/右侧面板，未发现专门走"围栏 → artifact 卡片 → 预览 → 版本 → 恢复"整链的用例。

**已确认边界**：
- artifact 是纯渲染器启发式对象，无协议、无模型寻址、不可用户编辑（源码直接确认，`store/artifacts.ts` 注释）。
- `[Preview: …](#preview/…)` 协议只有消费端，本快照无生产端调用者（`previewMarkdownHref` 无调用点）。
- 本地 HTML 文件只显示源码、artifact HTML 才执行（`preview-file.tsx:664-667`）。
- 无 notebook/画布/白板运行时（检索范围：全仓 `*.py`/`*.ts`/`*.tsx` 内 jupyter/notebook/draw.io/excalidraw/whiteboard，排除 node_modules/网站/技能目录；仅发现 `.ipynb` 读取与图标/文档提及）。

**未验证事项**（本次未运行）：
- 流式检测 → 卡片落定的实际时序与重挂载行为；
- webview/iframe 沙箱在真实 Electron 里的隔离强度与 console 采集行为；
- `read_preview` 桥在远程网关模式下的端到端延迟与超时表现；
- 版本注册表在"压缩/恢复/分支"后的重建正确性（依赖 `session.resume` 的转写完整度）；
- 消息平台 `MEDIA:` 递送的视觉形态（属于相邻类目，未深查）。

## 12. 关键源码索引

- `apps/desktop/src/lib/artifact-detect.ts`：围栏 → artifact 检测、slug、哈希、下载名
- `apps/desktop/src/store/artifacts.ts`：内存注册表、版本追加、淘汰
- `apps/desktop/src/store/preview.ts`：预览标签页模型与持久化策略
- `apps/desktop/src/app/chat/right-rail/preview-artifact.tsx`：artifact 沙箱 iframe 与版本 UI
- `apps/desktop/src/app/chat/right-rail/preview-pane.tsx`：URL webview 沙箱与 console/devtools
- `apps/desktop/src/app/chat/right-rail/preview-file.tsx`：文件渲染/diff/就地编辑与冲突
- `apps/desktop/src/lib/preview-targets.ts`、`lib/media.ts`、`lib/chat-messages.ts`：`#preview/`、`#media:`、`MEDIA:` 三协议消费端
- `apps/desktop/src/app/artifacts/artifact-utils.ts`：跨会话画廊挖掘
- `tools/open_preview_tool.py`、`tools/read_preview_tool.py`、`tools/focus_pane_tool.py`、`tools/desktop_ui.py`、`tools/read_window_tool.py`：桌面能力桥工具
- `tools/code_execution_tool.py`：模型侧 Python 沙箱（UDS/TCP RPC、白名单、审批）
- `tools/patch_parser.py`：v4a 结构化文件编辑
- `tools/tool_result_storage.py`：大结果落盘回读
- `agent/prompt_builder.py:793-830`：`MEDIA:` 协议的平台提示词
- `gateway/run.py:1550-1693`、`gateway/platforms/base.py:1180-1240`：媒体递送与权限
- `tui_gateway/server.py`：编辑快照与 inline diff 事件、预览重启临时 agent、`window.read.request` 桥（5870-5879）
- `hermes_state.py`、`tui_gateway/methods_session.py`：会话持久化与恢复
