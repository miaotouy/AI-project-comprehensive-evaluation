# Chat 横向对比（概览与跨类目导航）

> 对比对象：AIO Hub、AstrBot、Chatbox、Cherry Studio、DeepChat、Hermes Agent、Jan、LobeHub、Manifold Desktop、NextChat、Open WebUI、OpenCode、Pi、SillyTavern、VCPChat、VCPToolBox
>
> 对比更新日期：2026-08-11
>
> 依据：会话与消息管理、对话请求与上下文、Chat UI、消息渲染器四个类目的单项目调查笔记及横向对比；本文档只保留跨层综合结论
>
> 对比方法：本文档为导航性总览，详细表格已迁入三个新类目的横向对比；只保留能够同时解释数据层、执行层和交互层的综合结论
>
> 对比范围：跨层综合结论、选择提示与通用界面盘点；会话数据在[会话与消息管理横向对比](../会话与消息管理/会话与消息管理横向对比.md)，执行语义在[对话请求与上下文横向对比](../对话请求与上下文/对话请求与上下文横向对比.md)，用户工作流在[Chat UI 横向对比](<../Chat UI/ChatUI横向对比.md>)
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

> 迁移状态（2026-08-11）：本文档的详细表格已迁入三个新类目横向对比：
>
> - [会话与消息管理横向对比](../会话与消息管理/会话与消息管理横向对比.md)：会话单位、存储模型、分支、索引与搜索（数据侧）
> - [对话请求与上下文横向对比](../对话请求与上下文/对话请求与上下文横向对比.md)：SDK 主链、消息构建、流式持久化、中断
> - [Chat UI 横向对比](<../Chat UI/ChatUI横向对比.md>)：工作台、搜索入口、消息操作、停止反馈、键盘无障碍
>
> 本文档保留：结论摘要、跨层综合结论（SDK 选型、搜索、UI、中断）、选择提示表和通用界面盘点（待可选界面专题承接）。

## 结论摘要

十六个项目里，"消息构建""分支""搜索""流式持久化""中断"虽然名称相近，底层实现却分属不同层次。新增项目补充了几种边界：IM 事件流水线（AstrBot）、主进程会话运行时（DeepChat）、独立 Agent 后端（Hermes Agent）、前端直连模型（Jan、NextChat）、服务端协同聊天系统（Open WebUI）、主链尚未接通持久化的薄客户端（Manifold Desktop）、终端本地 Agent 会话运行时（Pi，自研 agent-loop + JSONL 追加型树会话），以及服务端 Agent 会话运行时（OpenCode，SQLite 权威 + 事件广播 + 客户端投影，Web 与 TUI 共用）。VCPToolBox 不提供最终用户聊天 UI，仅参与消息构建与网关编排对比。

## 跨层综合结论

### 横向看，SDK 选型实际在决定什么

1. **谁是消息的规范拥有者。** Chatbox、Cherry Studio、Jan 把 SDK 当作调用层契约，Session/Topic/Thread 仍由应用定义；AIO Hub、LobeHub、DeepChat 把规范放在自研运行时；Hermes Agent、Open WebUI 放在独立后端；SillyTavern 和 VCPChat 则依靠原始消息与扩展字段/协议标记。这个边界影响历史数据能否脱离当前 Provider 解释，也影响接入新 Provider 时只需增加适配器，还是要增加一套请求分支。
2. **标准化发生在哪一层。** 调用层标准化（Chatbox、Cherry Studio、Jan）主要处理 Provider 流差异；主进程/运行时标准化（LobeHub、AIO Hub、DeepChat）还统一工具、上下文和展示投影；AstrBot、Hermes Agent、Open WebUI 分别把这类职责放在事件流水线、Agent 会话后端和协同服务中；VCPToolBox 只统一请求预处理，会话仍由调用方负责。仅看依赖中是否出现 SDK，无法判断系统的标准化范围，比较时要先区分所在层级。
3. **Agent 是否被视为普通消息的扩展。** Cherry Studio 选择单独的 Claude Code SDK；DeepChat 把 Agent turn、pending input 和工具交互变成主进程 transcript 的一部分；Hermes Agent 让子代理本身成为真实子会话；LobeHub/AIO Hub 在自研运行时中统一承接；SillyTavern/VCPChat 则通过字段或协议标记扩展。它们对审批、工具步骤、恢复状态和子会话可见性的表达能力并不相同。
4. **短期接入速度与长期语义控制的交换。** 成熟 SDK 可以减少 Provider 适配工作，但项目需要接受其事件模型和升级节奏；自研主链可以按产品语义设计消息树、流式落盘和工具循环，同时承担兼容性、测试和迁移责任。SillyTavern 的多分支兼容、AIO Hub 的协议一致性，分别体现了这两种取向。
5. **故障应归因到哪里。** SDK 边界清晰时，可以把 Provider 错误与应用状态错误分层定位；协议/网关自研较多时，错误可能发生在消息重写、标记解释或递归工具循环中。排查这类问题需要同时保留原始请求、转换后请求和执行快照，否则很难定位模型输出偏差的具体环节。

评估 Chat 应用的 SDK 使用情况时，应比较五件事：**规范消息由谁定义、流式事件在哪里归一化、工具和 Agent 生命周期由谁承接、会话数据能否脱离当前 Provider 恢复，以及失败时能否观察到每次转换。** 这些问题比依赖名称更能解释架构取向。

### 搜索：索引、命中粒度和跳转能力仍是三件事

结论：Chatbox 与 DeepChat 已确认能从数据层命中并定位具体消息（Chatbox 走 IndexedDB Session 扫描，DeepChat 走 FTS5 全文索引 + 命中 message_id 定位）；LobeHub、Hermes Agent 具有数据库或搜索文档基础，但用户可见定位链路的证据不齐；Jan、Open WebUI、AIO Hub、Manifold Desktop 主要返回会话级结果；Cherry Studio 与 VCPChat 分别受虚拟 DOM 和多模态内容形态限制。现有笔记仍未确认任何项目完整满足"持久化消息索引 + 跨分支/跨会话命中 + 直接定位具体消息"三个条件（DeepChat 的 FTS5 覆盖消息级命中与定位，但索引的写入触发点和清理策略本次未完整追踪）。逐项目细节见[会话与消息管理横向对比](../会话与消息管理/会话与消息管理横向对比.md)与[Chat UI 横向对比](<../Chat UI/ChatUI横向对比.md>)。

### 中断/取消生成：按钮停止、任务取消和请求中止不是同一层

VCPChat 仍是"同一产品两条路径不对称"证据最完整的案例。Hermes Agent 的前端本地定稿、Manifold Desktop 的回调式 stop token、Open WebUI 的跨实例任务取消分别处在不同层级。其余项目缺少同等深度证据，只能标为未验证，不能从按钮存在推断请求已被中止。逐项目中断层级见[对话请求与上下文横向对比](../对话请求与上下文/对话请求与上下文横向对比.md)，用户可见的停止入口与反馈见[Chat UI 横向对比](<../Chat UI/ChatUI横向对比.md>)。

### UI 交互与呈现的跨项目结论

1. **"消息渲染"至少有四层含义**：AIO 当前把消息树编译成活动路径并完整挂载 DOM，再用 `content-visibility` 裁剪屏外渲染；它在 2025-11-02 至 2026-04-29 曾使用 TanStack Virtual，后因聊天场景的动态高度和滚动稳定性问题撤回。Chatbox/Cherry/Lobe/Jan 也把消息模型先编译成活动路径或 flat list；DeepChat 做测量驱动的窗口化，NextChat 只做固定页窗；SillyTavern/VCPChat/Manifold 主要增量或整段修改 DOM；VCPToolBox 只改第三方 DOM，不拥有消息列表。渲染实现细节在[消息渲染器横向对比](../消息渲染器/消息渲染器横向对比.md)。
2. **停止生成的视觉状态与执行状态可能不同**：VCPChat 单聊只通知远端，Hermes Agent 前端先本地定稿再请求后端中断、两者存在中间窗口，Manifold 的 stop token 不能打断阻塞读取；Open WebUI 将停止建模为可跨实例路由的任务取消。评估停止能力时，需要继续追到请求或任务控制层。
3. **输入区承载了大量 Agent 交互**：DeepChat 的 steer/queue/permission、Jan 的排队与附件、Open WebUI 的工具确认和终端事件，与 AIO/Chatbox/Cherry/Lobe/VCPChat 的附件、知识库、mention、审批共同组成了输入协议。
4. **窗口化与搜索存在结构性冲突**：Chatbox/Cherry/LobeHub/DeepChat 通过虚拟或窗口列表控制长会话成本，但 Cherry 的 DOM 搜索以及任何依赖已挂载节点的扩展会漏掉窗口外消息；NextChat 的固定页窗也需要显式移动窗口。AIO 曾经也有这一类窗口化方案，但在消息高度动态、倒序加载和滚动定位稳定性上付出的复杂度过高，后来改为完整 DOM + `content-visibility`，以保留真实 DOM 定位能力并把成本转给浏览器的屏外渲染裁剪。SillyTavern/VCPChat 没有这个漏搜原因，却把成本转移到整段 DOM。
5. **UI 调查应记录"呈现投影"**：AIO 的 linear/force-graph、Cherry 的 `TopicBranchPanel` 消息树图（React Flow，选分支辅助面板）、Open WebUI 的 side-by-side/MoA 与 Overview 消息树图（SvelteFlow，点击节点切分支）、VCPChat 的 bubble/panel/immersive、Chatbox 和 Jan 的分支版本导航，都说明同一份会话数据可以有多种用户可见投影；仅记录 `Session/Topic/Thread` schema 无法解释用户实际如何切换、编辑、停止和定位。

## VCPToolBox：不参与会话/UI 对比，但参与消息构建

VCPToolBox 不提供最终用户聊天主界面，但仍负责消息构建。它把调用方提交的历史归一化为 OpenAI `messages`，在首次请求前完成裁剪、注入和预处理；模型输出 VCP 工具标记后，再把 assistant 正文和工具结果 user payload 追加到内存上下文并递归请求。`FinalContextViewer` 只捕获首次上游 fetch 前的最近 5 份内存快照，不包含后续工具递归消息，也不是会话数据库。AdminPanel-Vue 是独立进程（监听 `PORT+1`），与聊天主链物理解耦；OpenWebUISub 是运行在第三方聊天页面里的浏览器脚本。给模型的工具结果使用 `<!-- VCP_TOOL_PAYLOAD -->` user 消息，给前端的可见结果由 `vcpInfoHandler.js` 另行写入 SSE/最终 JSON，两者不能混为同一份消息。完整证据链见[对话请求与上下文横向对比](../对话请求与上下文/对话请求与上下文横向对比.md)的 VCPToolBox 一节。

## 选择提示（基于已核实机制）

| 侧重点 | 项目 | 已确认的边界 |
| --- | --- | --- |
| 数据库级消息树与事务约束 | Cherry Studio | SQLite 有外键和 CHECK 约束；三层数据管道增加调试复杂度 |
| 跨 IM 平台事件流水线、群聊唤醒与 follow-up | AstrBot | 核心单位是 UMO 和异步事件，WebChat 只是一种入口 |
| 主进程权威 transcript、Agent 输入队列与工具交互 | DeepChat | main/renderer 之间仍有 IPC revision、cursor 和事件顺序边界 |
| CLI/TUI/桌面共用 Agent 后端、跨压缩 lineage | Hermes Agent | 会话句柄（sid）与持久 session id 必须区分，压缩轮转后按 lineage root 重锚 |
| 本地模型、AI SDK 流式 UI 与消息版本树 | Jan | 桌面端每轮整写 JSONL，未完成回合不恢复 |
| 应用层树与分支记忆 | AIO Hub | 搜索无索引，崩溃后生成状态不自愈 |
| 简单会话记录、归档优先于删除 | Chatbox | 恢复归档不会重排，拖拽排序仅限同分组 |
| Agent 工具过程的可观察流程 | LobeHub | 双层 store 各自 parse；审批逻辑位于全局 store |
| 纯客户端部署，集中保存 Mask、摘要和工具状态 | NextChat | IndexedDB/localStorage 是主存储，本地数据与同步边界需单独评估 |
| 服务端权限、分享、多模型与跨实例任务控制 | Open WebUI | history/消息表双写，Socket.IO 事件状态组合较多 |
| 文件级分支、检查点与社区扩展 | SillyTavern | 长聊天不虚拟化；正则按展示、prompt、存储位置分层，渲染结果可能随聊天长度变化 |
| 多角色群聊与长期 Topic 关系 | VCPChat | 单聊没有本地 abort，可靠中止依赖远端 |
| 终端本地编码 Agent、追加型树会话与工具循环 | Pi | 单会话单循环；消息编辑以分支表达；无消息级搜索索引；系统提示不随会话保存 |
| 服务端 Agent 会话运行时、事件广播与多前端共用 | OpenCode | SQLite 权威 + SSE 投影；删除式 revert 与复制式 fork；无消息级全文搜索；Web/TUI 两套渲染栈 |

Manifold Desktop 当前更适合作为"聊天主链尚未接通持久化时会出现哪些断层"的对照样本，不宜仅凭已存在的 SessionManager API 判断会话能力已经完成。

以上内容只描述已核实的产品与源码机制，不构成性能、安全或 Agent 能力排名。分支、流式和搜索的详细证据见对应类目的单项目笔记与横向对比；工具调用权限与 Agent 配置见 `项目调查笔记/Agent工具`；消息渲染层的公共问题见 `项目调查笔记/消息渲染器`。

## 通用界面盘点（待可选界面专题承接）

> 本节内容（2026-08-05 增补，2026-08-11 迁移时保留）是通用界面基础设施的跨项目盘点，不属于 Chat UI 主文；待"可选界面专题"建立后迁移。覆盖范围：弹窗底层、通知/Toast、主题切换、图片预览、动画方案，以及各项目的特殊实现差异。VCPToolBox 不提供聊天主界面，不参与本节对比。

### 弹窗/对话框：六种互不相同的底层技术栈

| 项目 | 弹窗底层 | Esc/遮罩关闭 | 焦点管理 |
| --- | --- | --- | --- |
| AIO Hub | 自研 `BaseDialog.vue`（非 Element Plus），自增 z-index，300ms 入退场动画 | 支持（由 `showCloseButton`/`closeOnBackdropClick` prop 控制） | 基本缺失；唯一例外：`RenameDialog` 输入框有 `autofocus` |
| Chatbox | 三套并存：Mantine `Modal`（主力）+ `vaul`（移动端底部弹起）+ Radix `Dialog`（预留）；`@ebay/nice-modal-react` 统一管命令式调用 | 逐弹窗配置：登录/许可证类三项全禁；`trapFocus={false}` 在四个弹窗里有意关闭（iOS Safari 文本选中 workaround） | `trapFocus={false}` 的四个弹窗键盘 Tab 可穿透到背景——有代码提交记录的已知取舍 |
| Cherry Studio | 自建 `@cherrystudio/ui` 包裹 Radix `Dialog`；`services/popup` 用 `useSyncExternalStore` 做 store | 支持；两阶段关闭，延迟 200ms 播放退场动画 | Radix `DialogContent` 默认交给 `FocusScope` 管理焦点；业务侧可用 `focusOnClose` 指定关闭后的焦点落点 |
| LobeHub | `@lobehub/ui` 的命令式 `createModal`/`confirmModal`（主流）+ `ImperativeModal` 兼容层（迁移期遗留） | 高危操作（如清空工作区）把 `maskClosable` 设为 `false` 并要求勾选确认框；其余遮罩点击可关闭 | 业务调用方未发现统一的显式配置；`@lobehub/ui/base-ui` 内部是否有 focus trap 未下钻，结论应保留为未核实 |
| SillyTavern | 原生 `<dialog>` + 自研 `Popup` 类（非 jQuery UI Dialog）；阻塞性弹窗需**双击 Esc** 强制关闭（注释自曝为"踩坑后留下的防御代码"） | **点遮罩不会关闭**（与大多数现代弹窗库相反） | 无 |
| VCPChat | 全部自定义 DOM；通用 Modal 用 `<template>` 懒加载 + `modal-ready` 事件通知 | 确认对话框支持 Esc/Enter/遮罩点击；无 focus trap，Tab 可穿透背景 | 无 focus trap |

**跨项目结论**：SillyTavern 的遮罩点击不会关闭弹窗；Chatbox 有可追溯的提交记录说明关闭 focus trap 的原因。焦点管理覆盖不一：Cherry 的 Radix 基础层提供 `FocusScope`，其余项目在自动聚焦、关闭后的焦点落点和业务控件语义上各有缺口；LobeHub 的 `@lobehub/ui` 包内部实现尚未核实。

### 通知/Toast：每个项目各自为战

| 项目 | 实现 | 位置 | 特殊行为 |
| --- | --- | --- | --- |
| AIO Hub | 三层：`customMessage`（ElMessage 包装，offset 54px 避开无边框标题栏）→ `errorHandler` 四级分发（CRITICAL 走常驻 `ElNotification`，duration:0）→ 独立 `NotificationCenter`（持久化） | 顶部 | CRITICAL 级常驻不消失 |
| Chatbox | 两套分工：MUI `Snackbar`（聊天主流程，右上角，3s）+ `sonner`（Settings 弹窗内部，底部居中，`z-index: 2147483647`）；错误 toast 先出原文再追加异步翻译 | 右上角 / 底部居中 | 多条 MUI toast 会互相重叠（未处理堆叠位移） |
| Cherry Studio | 自研 store（非 antd/sonner），`role="alert"`/`role="status"` 区分严重程度，error 默认不消失 | 顶部居中 | 默认 3s，error 永不自动消失 |
| LobeHub | antd `App.useApp()` 单例（`AntdStaticMethods`），桌面端整体下移避开 Electron 标题栏；另有独立自绘悬浮通知卡片组件 | 顶部（偏移）+ 悬浮卡片 | 两套并存：antd 管临时提示，自绘卡片管持久通知 |
| SillyTavern | `toastr` 库（88 处调用分散在 86 个文件，无统一封装层）；`fixToastrForDialogs()` 专门处理弹窗打开时 toast 被遮罩挡住的问题；`escapeHtml:true` 防 XSS | 右上角 | 有独立的 `action-loader.js` 子系统管"阻塞遮罩单例 + 可堆叠 toast"，toast 可带停止按钮直调 `stopGeneration()`（聊天主链交点见 Chat UI 横向对比） |
| VCPChat | 自定义，默认 7 秒消失，`tool_approval_request` 永不消失；通知侧栏打开时抑制浮动 Toast；窗口获焦时自动清理超时残留 toast；新 toast 插入顶部（prepend）而非追加尾部 | 左上角 prepend | **不发任何系统桌面 `Notification`** |

**跨项目结论**：多条 toast 并存时，Chatbox 的 MUI Snackbar 会重叠，SillyTavern 的 toastr 又分散在 86 个文件中，没有统一封装。Chatbox Settings 使用的 sonner 和 VCPChat 的 prepend 方案提供了明确的堆叠位置管理。

### 主题切换：热切换与整窗口重载

| 项目 | 切换机制 | 跟随系统 | 持久化位置 |
| --- | --- | --- | --- |
| AIO Hub | CSS 变量/class 切换 | `matchMedia('(prefers-color-scheme: dark)')` 注册 `change` 监听；仅 `auto` 模式响应 | `settings.json`（非 localStorage） |
| Chatbox | MUI 主题 + Tailwind `dark` class + Mantine `colorScheme` **三套各管一段**，`realTheme` 单一状态源统一驱动 | ✓（桌面端 `nativeTheme.on('updated')`，Web 端 `matchMedia` listener） | `localStorage['initial-theme']`（供首屏同步读取防闪烁） |
| Cherry Studio | Electron 主进程 `nativeTheme.themeSource` 为权威，IPC 广播同步渲染层；CSS 变量遵循 Shadcn 契约（无前缀），自定义主色直写行内 style | ✓（`nativeTheme` 原生支持） | Electron 主进程 store |
| LobeHub | `next-themes` 管 light/dark/system 解析和 `data-theme` 属性；`@lobehub/ui` 的 `ThemeProvider` 套色板 token——**两层分离，各自独立持久化** | ✓（`next-themes` 原生支持） | `next-themes` 的 localStorage（明暗）+ 用户 store + cookie 镜像（强调色/中性色） |
| SillyTavern | CSS 变量运行时改写 + 服务端存储；导入主题时若含 `@import` 专门弹出安全警告 | **✗（全仓库无 `prefers-color-scheme`）** | 服务端（非 localStorage） |
| VCPChat | **整份覆写 `themes.css` 文件，然后调用 `mainWindow.reload()` 整窗口重载** | Electron `nativeTheme.on('updated')` 监听并广播 `theme-updated` IPC；系统变化时不必用户手动切换 | `settings.json` 的 `currentThemeMode` + 本地 `themes.css` |

**跨项目结论**：VCPChat 切换主题时会 reload 整个窗口，可能出现白屏；SillyTavern 未跟随系统深色模式。Chatbox 同时维护三套主题机制，深色背景 `#242424` 在 MUI 和 Tailwind 两处分别硬编码，修改时需要同步两处。

### 图片预览：页面内灯箱与独立子窗口

| 项目 | 图片预览实现 | 特殊能力 |
| --- | --- | --- |
| AIO Hub | `viewerjs` 库 | — |
| Chatbox | `react-zoom-pan-pinch`（`TransformWrapper`），缩放 0.1×–8×，鼠标/触控手势 + 拖动平移 | 支持 `extraButtons` 注入（如"设为头像"） |
| Cherry Studio | `ImageViewer.tsx` + `@cherrystudio/ui` `ImagePreviewDialog` | 缩放、旋转、翻转、多图前后导航、复制/下载 |
| LobeHub | `ImageFileListViewer` + `@lobehub/ui` `PreviewGroup`/`Image` | 业务侧确认是灯箱预览并支持组内切换；缩放/旋转/下载等细节在 UI 包内部 |
| SillyTavern | 复用 `Popup` 弹窗，以 CSS class toggle 实现灯箱效果；另用 `jquery.izoomify` 提供鼠标悬停放大镜 | 触屏体验存疑（未实测） |
| VCPChat | **独立 Electron 子窗口**，8 种绘图工具、本地 Tesseract.js OCR（懒加载）、缩放范围 0.05×–32× | 唯一支持 OCR 识别图片文字 |

**跨项目结论**：VCPChat 的图片预览是独立进程子窗口（代价是开销大），其它项目走页面内灯箱/弹窗；只有 VCPChat 集成了 OCR 能力。Cherry Studio 的预览能力已在业务和 UI 包两侧核实，LobeHub 的灯箱接入已核实，只有其底层 UI 包提供的具体工具按钮能力仍未下钻。

### 动画方案：只有 LobeHub 引入了 framer-motion 体系

- **AIO Hub**：自研 CSS transitions + Element Plus 内置动效
- **Chatbox**：无 framer-motion；`tailwindcss-animate` + Mantine 内置过渡预设 + `vaul` 弹簧动画 + 手写 SVG `<animate>` + 手写 CSS keyframes；消息卡片首次出现**无入场动画**
- **Cherry Studio**：无 framer-motion；`tw-animate-css` + Radix `data-state` 驱动 + 手写 CSS keyframes；折叠展开是 `hidden` 硬切换，**无高度渐变过渡**
- **LobeHub**：`motion/react`（framer-motion 新包名）用在 `WorkflowCollapse` 折叠动效和文档编辑器侧栏滑动；消息本身进场**无动画**；且两处自定义动画对全局 `animationMode` 开关的遵守程度不一致（一处读、一处不读）
- **SillyTavern**：自研 `stream-fadein.js`（流式输出渐显）+ jQuery UI + CSS transitions；消息完成渲染后触发 `CHARACTER_MESSAGE_RENDERED` 事件供扩展挂钩
- **VCPChat**：CSS transitions；三种 presentation mode 切换是 body class 变换，由 CSS 控制

**跨项目结论**：六个项目都没有为消息卡片首次出现设置明显的入场动画。LobeHub 引入了 framer-motion，但只用于少数组件；Cherry Studio 的折叠展开采用 `hidden` 硬切换，属于代码中明确可见的实现方式。

### 各项目的特殊实现差异（汇总）

- **AIO Hub**：主题持久化在 `settings.json` 而非 localStorage（与"通常在浏览器层存"的预期相反，因为是 Tauri 原生应用）。
- **Chatbox**：文件拖入输入区**没有任何高亮遮罩或视觉反馈**；桌面端 `SessionItem` **没有右键菜单**；初始断点判定用 599.95px，后续响应式用 640px，两个数字之间存在窄缝（聊天主链交点见 Chat UI 横向对比）。
- **Cherry Studio**："助手回复完成通知"开关可勾选，但全仓库找不到任何发送调用——**是个不生效的死开关**。
- **LobeHub**：移动端是独立路由树 + 独立构建产物（`vite.config.ts` 按 `isMobile` 切 entry），不是同构响应式；资源管理器的文件拖拽是团队主动放弃 `dnd-kit`、自建原生 HTML5 drag/drop（注释明确写了性能理由）。
- **SillyTavern**：swipe（候选回复切换）在移动端是**点按钮，不是划手势**，与功能名字暗示的手势操作不符；主题系统的 CSS 是服务端存储而非 localStorage，切换后需要页面刷新。
- **VCPChat**：compact navigation 由 `sidebarAvatarOnly` 字段显式控制，**不是宽度断点自动触发**；表情包选择器是平铺图片网格，无搜索无分类，点击插入原始 `<img>` HTML 标签。

## 迁移与导航

- 会话单位、存储模型、分支、索引与搜索（数据侧）：[会话与消息管理横向对比](../会话与消息管理/会话与消息管理横向对比.md)
- SDK 主链、消息构建、流式持久化、中断：[对话请求与上下文横向对比](../对话请求与上下文/对话请求与上下文横向对比.md)
- 工作台、搜索入口、消息操作、停止反馈、键盘无障碍：[Chat UI 横向对比](<../Chat UI/ChatUI横向对比.md>)
- 消息渲染实现：[消息渲染器横向对比](../消息渲染器/消息渲染器横向对比.md)
- 通用界面盘点（弹窗/Toast/主题/图片预览/动画）：待可选界面专题承接，暂保留于本文档"通用界面盘点"一节。
