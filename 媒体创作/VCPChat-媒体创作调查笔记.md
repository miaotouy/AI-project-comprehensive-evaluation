# VCPChat 媒体创作调查笔记

> 调查对象：`https://github.com/lioensky/VCPChat`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`89e02b778d626078be91dfbad01e5c9554c47f76`（分支：`main`）
>
> 调查方式：只读静态源码梳理；复核媒体创作横向对比、独特功能笔记与 Scriptorium、HumanToolBox ComfyUI 模块、IPC 和 Agent 插件实现；运行轻量 Node 协作者契约测试与语法检查，不启动 Electron、ComfyUI、VCPToolBox 或外部模型服务
>
> 调查范围：以 Scriptorium 的 VDOCX/VPPTX 可继续编辑工程、媒体资产、导出和 Agent 审阅协作为完整主链；补充 HumanToolBox ComfyUI 配置/工作流管理链及其外部执行边界。Loom、Hi-Fi 播放器、普通附件和 VCPToolBox 内的实际 ComfyUIGen 执行不作为本笔记的媒体工程主链
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPChat 是媒体创作类目的扩展样本，核心不是统一的图像或视频生成工作台，而是两个对象和执行域不同的创作面。

- **Scriptorium** 是本仓库内可确认的 M3 资产与工程工作区，且具有 M5 Agent 驱动创作的协作通道。它将 VDOCX 连续流文稿和 VPPTX 演示保存为可继续编辑的工程，保存真源、内容寻址资源与文脉；人类可编辑、预览、导入和导出，Agent 可读取语义、源码和截图，但写入以带署名、修订号和人工回执的 PR 为界。
- **HumanToolBox ComfyUI 面板** 是 ComfyUIGen 的人类配置面，能保存连接、参数和工作流模板，并将 ComfyUI API JSON 转换为后端插件使用的模板。VCPChat 不在此链中调用 ComfyUI 生成图片或保存生成历史；配置文件和模板由外部 VCPToolBox 插件目录持有，真实生成仍依赖另行运行的 ComfyUI 与后端插件。

因此，VCPChat 满足媒体创作类目对“专用入口、工程/资产对象、继续编辑与结果交付”的要求，但不应等同于以统一媒体任务、模型目录和资产库为核心的 M1 工作站。其完整主链应以 Scriptorium 媒体工程为准；ComfyGen 是跨仓库配置交接，不与 Scriptorium 的工程、资源或文脉合并。上述为源码直接确认的静态结论；实际编辑、渲染、Agent 审批、导出和 ComfyUI 连接均未运行验证。

## 系统边界与完整主链

本笔记的主链从 Scriptorium 的文档或演示工程开始。用户由托盘“文坊”打开独立窗口；主进程初始化文档 IPC 与 Agent 控制服务。VDOCX 使用 Markdown-first 的混合源码和独立文档 CSS，VPPTX 的每页保存完整 HTML Scene 和共享 deck CSS。两种格式均以工程中的源文件而非渲染 DOM 为真源，资源以 SHA-256 进入 ZIP 容器，文脉保存版本、PR 与审批信息。入口与初始化见 `modules/trayManager.js:29`、`modules/ipc/desktopHandlers.js:779-781`、`main.js:1083-1092`。

```text
人类新建/导入 VDOCX 或 VPPTX，或 Agent CreateProject
  -> 规范化混合源码或完整 Scene，检查可编程内容
  -> 工程 ZIP 写入 AppData/ScriptoriumDocument/VDOCX|VPPTX
  -> 渲染、直接编辑或源码编辑均回写唯一真源
  -> 图片/音频/视频等资源按 SHA-256 写入工程并在编辑期映射为 blob URL
  -> 保存文脉、快照和 PR/审批回执
  -> 分页 HTML、演示 HTML 或 PDF 导出为独立交付物
  -> Agent 读取语义/源码/截图，提交带 expectedRevision 的 PR
  -> 人类批准后合并并形成新修订；拒绝、冲突、失败和超时保留相应记录
```

Agent 直接建工程时，控制服务先让文档内核构建 ZIP，再检查结果大小不超过 100 MB、ZIP 文件头与目标路径冲突策略；默认重名，覆盖已有工程必须提供当前文件 SHA-256。实际写入经文档处理器完成，且不会替换当前窗口，除非请求打开新工程。此链路可见 `modules/services/scriptoriumAgentControlService.js:243-407`。

HumanToolBox 的 ComfyUI 链则单独成立：用户从工具卡设置按钮打开配置抽屉，读取或保存后端插件的配置和工作流 JSON；导入时在 VCPChat 主进程定位 VCPToolBox 的 `WorkflowTemplateProcessor` 并转换模板。配置变化会通知工具箱渲染进程，但本仓库未见该面板提交 ComfyUI prompt、轮询任务或保存图片产物的可执行路径，故不能据此推断 VCPChat 自己拥有 ComfyUI 任务历史。入口见 `VCPHumanToolBox/renderer.js:1608-1650`，IPC 实现见 `VCPHumanToolBox/ComfyUImodules/comfyui-ipc.js:82-92,94-259`。

## 1. 创作入口、触发者与事实对象

Scriptorium 的用户入口是独立 Electron 文坊窗口，支持新建、打开、保存、另存、导入和导出；Agent 入口是 `ScriptoriumCollaborator` 的 direct/hybridservice 插件。插件通过 `ScriptoriumAgentControlService` 确保窗口和渲染侧 Agent 端口在 20 秒内就绪，再将请求交给文档处理器，因而 Agent 操作的对象是当前 Scriptorium 工程，而非聊天消息附件。等待与请求转发见 `modules/services/scriptoriumAgentControlService.js:146-168`。

工程事实对象分为四层：VDOCX 的混合正文与 document CSS、VPPTX 的完整页面 Scene 与 deck CSS、ZIP 内按 SHA-256 内容寻址的媒体/字体资源，以及记录刻点和 Agent PR 的文脉。容器至少分离 manifest、源码、文脉和资源，工程资源可记录 MIME、原始尺寸和时长；相同二进制可去重。该对象模型和容器布局在 `ScriptoriumModules/README.md:393-425` 说明，实际容器实现位于 `ScriptoriumModules/vdoc-container.js`。

除工程内资源外，Scriptorium 还维护运行期样式包与 SVG 资产包。Agent 可查询、创建、整体替换或删除非内置包；内置包只读。已插入文档的 SVG 是自包含快照，删除运行期包不会破坏工程内既有实例。这使图形资产可在多作品间复用，但运行期资产包与单个工程 ZIP 并非同一持久化层，见 `VCPDistributedServer/Plugin/ScriptoriumCollaborator/plugin-manifest.json:100-147`。

ComfyGen 的事实对象不是 VCPChat 工程：配置和模板写入由 PathResolver 找到的 VCPToolBox `Plugin/ComfyUIGen/` 目录。面板可管理连接地址、模型、尺寸、种子、提示词、LoRA 与模板；README 声明默认连接为本地 `http://localhost:8188`。这证明的是跨仓库的配置管理入口，不能证明本仓库内有生成文件、任务或资产记录，见 `VCPHumanToolBox/ComfyUImodules/README.md:5-48`。

## 2. 参数、素材与模型/渲染执行

Scriptorium 的普通内容可使用 Markdown、HTML、CSS、LaTeX 与 Mermaid；脚本、Canvas、WebGL 或需稳定身份的内容必须放入带唯一 ID 的可编程岛。渲染编辑不是将 DOM 序列化回正文：编译器为编辑区保存源码字符范围和内容哈希，编辑操作提交带 expected 原文的区间事务；边界、哈希或修订过期时拒绝写入。该机制使用户在渲染态编辑仍能保留未改动源码，见 `ScriptoriumModules/README.md:38-153` 与 `vdoc-hybrid-compiler.js`。

VPPTX 每页以完整 HTML Scene 保存，页面可以声明样式、依赖和内联脚本。运行时为页面注入根对象和生命周期管理器；切页、重渲染或关闭时停止已追踪的帧与定时器。支持的 Anime.js 与 Three.js CDN 可本地化，未知公网脚本变成不可执行的审计声明。这里的渲染执行在 Scriptorium/Electron 浏览器运行时，而非 ComfyUI 或 FFmpeg，见 `ScriptoriumModules/README.md:195-220,256-272`。

ComfyUI 面板把用户参数写入外部插件配置；工作流保存前校验名称，导入的 API JSON 由 VCPToolBox 中的转换器处理。只有模板含指定 WeiLin 节点时才自动注入 LoRA；其他模板不会被强行改写。该条件和参数行为属于配置转换，实际模型、节点、队列与图片落盘仍在外部 ComfyUI/VCPToolBox 边界之外，见 `VCPHumanToolBox/ComfyUImodules/README.md:16-39` 与 `comfyui-ipc.js:131-175,216-259`。

## 3. 任务状态、异步回调与取消

Scriptorium 的长期状态是工程修订与文脉，不是统一的媒体生成队列。Agent 对当前工程的写入会先形成 PR；其状态可为 `pending`、`applied`、`rejected`、`conflict` 或 `failed`。提交时和批准时都检查基础修订与文档身份，`requestId` 用于避免重试重复提案；超时只返回等待审批的结果，提案不会静默应用。PR 主链见 `ScriptoriumModules/README.md:308-353,372-389`，插件参数适配位于 `ScriptoriumCollaboratorService.js:784-817`。

视觉上下文是一个短期异步动作：服务等待文档语义结果后调用 Electron `capturePage`，回传 Markdown 摘要和 data URL 图片。对演示页可请求渲染稳定等待；串行命令中某一步失败时，后续停止而此前成功的文本或图像回执保留并标为 `partial_failure`。这是 Agent 观察/回流机制，不是可恢复的媒体生成任务系统，见 `modules/services/scriptoriumAgentControlService.js:182-240` 与 `ScriptoriumCollaboratorService.js:1020-1034`。

本次检查范围内未找到 Scriptorium 面向用户的“取消导出/取消渲染”或跨重启恢复未完成导出任务的机制；也未找到 ComfyGen 配置面自身的提交、进度、取消、回调和重试实现。前者不等于项目其他模块绝对不存在异步控制，后者符合其仅配置外部插件的边界。

## 4. 结果、历史、资产与工程持久化

工程本身是 Scriptorium 的主要产物和持续性单位。`CreateProject` 经过规范化与可编程内容审查后生成 VDOCX 或 VPPTX ZIP，写入 `AppData/ScriptoriumDocument/VDOCX|VPPTX`；默认同名改名，显式覆盖需要现有文件哈希。文脉还保留源码变更、渲染结果差异、作者、审批和工程内嵌快照，因此恢复是新建一条可审计记录而非删除后续历史。落盘约束见 `modules/services/scriptoriumAgentControlService.js:243-407`，文脉语义见 `ScriptoriumModules/README.md:372-425`。

媒体资源使用内容寻址，工程打开时会校验资源路径、ID 和实际哈希；编辑期以受生命周期管理的 blob URL 使用，导出时才按目标格式封装。该设计支持工程内去重和来源可读性，避免把大段 Base64 写入正文。检查范围内未确认跨工程的中央媒体库、全局资源搜索索引或对位图/音视频的版本 DAG；应将这些未确认能力与工程内资源和运行期 SVG 包区分。

## 5. 预览、编辑、导出与复用

用户可在连续编辑、阅读/放映预览、混合源码和 CSS 源码四个工作面间切换。VDOCX 的渲染态编辑最终回到唯一源码；VPPTX 支持逐页 Scene 编辑。用户可导入 HTML、Markdown、TXT、RTF、DOCX 和 PPTX，Office 导入会转换为 VDOC 工程，不承诺原格式的像素级或无损往返。可导出连续流、分页或放映 HTML，以及 PDF；HTML 成品包含所需运行依赖和资源，可脱离编辑器在现代浏览器阅读或放映。实现范围与边界见 `ScriptoriumModules/README.md:429-497,604-619`。

Agent 可以读取文档信息、渲染文本、目录、章节、源码、视口源码和视觉上下文；长文档先取目录再读章节，避免将全文直接塞入上下文。它可通过 PR 修改源码或增删页面，也可直接创建新工程。样式包和 SVG 包可成为后续作品的可复用素材，但针对当前文档的变更仍经审阅，不可由 Agent 自行开启自动允许。命令族见 `plugin-manifest.json:25-152`。

## 6. Agent 回流、插件与外部依赖

`ScriptoriumCollaborator` 是 VCP 分布式服务器中的 direct 插件，manifest 声明 hybridservice、direct 通信和 330 秒超时。服务按命令把读取、截图、PR、页面修改、工程创建和资产包操作交给控制服务；控制服务再与当前 Scriptorium Electron 窗口通信。工程创建可直接回传路径、文件 SHA-256、大小及可编程内容审查信息；PR 则回传审批结果。这让 Agent 结果回流到 VCP 工具协议，同时把实际写入交给窗口侧的人类协作流程，见 `plugin-manifest.json:1-16`、`ScriptoriumCollaboratorService.js:890-1003`。

Scriptorium 的外部依赖是 Electron、VCP 分布式服务及浏览器渲染依赖。它不依赖 ComfyUI 才能编辑或导出工程。反过来，ComfyGen 必须依赖本地/远程 ComfyUI、VCPToolBox 的 ComfyUIGen 插件及其工作流转换器；HumanToolBox 只是通过本地文件和 IPC 管理这些外部对象。横向比较时应保持这两条依赖链分开。

## 7. 权限、资源边界与失败恢复

Scriptorium 的内容防线包括 HTML/CSS 清理、依赖本地化、未知外部脚本降级、JavaScript allow/warn/refuse 审查、运行时清理和 Electron 隔离。拒绝规则覆盖 Node、进程、文件系统、Electron/IPC、动态求值、构造器逃逸、危险导航与 file URL；网络、持久化存储、全局事件、持续任务和 WebGL 会产生警告。规则审查并非通用恶意 JavaScript 沙箱，用户关闭审查也不关闭 CSP、依赖本地化或 Agent PR 审批，见 `ScriptoriumModules/README.md:545-564`。

并发与覆盖防护有两层：渲染编辑的源码范围、哈希与 expected 原文检查，以及 PR 的 expectedRevision/批准时复检。工程创建的覆盖另要求预先提供文件 SHA-256。创建 ZIP 限制为 100 MB；模板工作流与 ComfyUI 配置保存会校验工作流名称，但本次未追踪外部 VCPToolBox 转换器对工作流节点和模型请求的资源限制。

## 8. 设计取舍、已确认边界与未验证事项

**设计取舍与已确认边界**：

- Scriptorium 选择“工程 + 真源 + 审阅文脉”而不是媒体任务表。它适合可继续编辑的富文档、演示、图形和可编程内容，不提供已确认的统一图像/视频模型队列。
- 人类编辑渲染结果与 Agent 编辑源码汇入同一真源，但 Agent 不能直接改写当前窗口；PR、署名、幂等请求与人工回执优先于自动化速度。
- 工程内媒体按内容哈希去重，运行期 SVG/样式包可复用；本次未确认一个覆盖所有工程的中央资产库或统一检索界面。
- ComfyGen 是 VCPChat 到 VCPToolBox/ComfyUI 的配置桥。它不是 VCPChat 内部的图片生成执行器，也不与 Scriptorium 共享任务、历史或资产身份。
- Loom 可由 Agent 创建可编程网页，Hi-Fi 模块可播放音频；在已读主链中，它们未与 Scriptorium 工程或 ComfyGen 生成记录形成统一对象链，故留在相邻类目，不重复计入本笔记主贡献。

**未验证事项**：

- 未启动 Electron，未实际创建、编辑、保存、导入或导出 VDOCX/VPPTX；渲染态编辑映射、媒体播放、分页、截图、资源哈希校验和 HTML/PDF 导出的真实效果未实测。
- 未连接 VCP 分布式服务或真实 Agent，PR 审批、自动允许策略、修订冲突、超时提案留存与工程回溯均只由静态路径和轻量契约测试支持。
- 未运行 ComfyUI、VCPToolBox 或外部模型，未验证连接测试、工作流转换、LoRA 注入、图片生成、队列状态、失败重试和生成结果回流。
- 未验证 Office 导入的版式保真、第三方脚本审查在真实不可信输入下的隔离效果、超大型媒体/WebGL/长动画的资源表现。

## 9. 关键源码索引

- 文坊入口与初始化：`modules/trayManager.js:29`、`modules/ipc/desktopHandlers.js:779-781`、`main.js:1083-1092`、`modules/ipc/docxHandlers.js`、`preloads/docx.js`。
- 工程模型、容器与编辑：`ScriptoriumModules/README.md`、`vdoc-core.js`、`vdoc-container.js`、`vdoc-hybrid-compiler.js`、`scriptorium-document-store.js`、`scriptorium-flow-editor.js`、`scriptorium-deck-editor.js`、`scriptorium-export.js`。
- 资源、运行时和文脉：`scriptorium-media.js`、`scriptorium-programmable-content.js`、`scriptorium-runtime.js`、`scriptorium-lineage-store.js`、`scriptorium-agent-port.js`。
- Agent 协作：`VCPDistributedServer/Plugin/ScriptoriumCollaborator/plugin-manifest.json`、`ScriptoriumCollaboratorService.js:560-1155`、`modules/services/scriptoriumAgentControlService.js:146-418`、`tests/scriptorium-collaborator.test.js`。
- ComfyGen 配置边界：`VCPHumanToolBox/renderer.js:1608-1650`、`VCPHumanToolBox/ComfyUImodules/ComfyUI_UIManager.js`、`comfyui-ipc.js:82-356`、`PathResolver.js`、`ComfyUImodules/README.md`。
- 交接依据：[`媒体创作横向对比`](媒体创作横向对比.md)、[`VCPChat 独特功能调查笔记`](../独特功能/VCPChat-独特功能调查笔记.md)、[`媒体创作分类边界研究`](../独特功能/媒体创作分类边界研究.md)。
