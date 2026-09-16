# RikkaHub 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-09-15
>
> 代码快照：`8e304bb1cc641e4ea772869ab9fb8c5b9b71cffb`（分支：`master`）
>
> 调查方式：静态源码调查；按 artifact/canvas/代码执行/沙箱/媒体持久化等关键词检索全仓（Kotlin、TypeScript、资源 HTML）；逐条阅读消息模型、流式解码、输出转换器、消息渲染、WebView 组件、生成媒体页、videogen 模块与内嵌 Ktor 服务器路由；对照本仓库 `AGENTS.md` 与既有笔记结构；未构建、未运行应用，未连接设备
>
> 调查范围：模型输出从生成到展示、运行、编辑、持久化、重开与回流的主链路；代码块与 HTML/SVG/Mermaid 预览；本地 JavaScript 工具与工作区沙箱边界；生成图片、音频、视频对象的物化与生命周期；内嵌 Web 服务器与 web-ui 的预览投影。模型推理调度、Provider 协议细节、搜索与语音 Provider 实现、UI 视觉审美不在本次范围
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

RikkaHub 是原生 Android 客户端，模型输出没有独立于消息的 artifact、canvas 或工作区对象协议。文本、代码块、图片、音频、文档、工具结果都只是消息 part 的变体，随会话消息以 JSON 落库；从「可寻址对象 + 生命周期」的角度看，当前快照只承认两类结果：消息 part 与文件。

本类目因此落在「受控运行环境」上，机制主线有四条：

- **代码块是展示对象，不是执行对象。** 聊天界面里代码围栏只有语言标签、下载、复制、折叠；仅当语言为 html/svg 且围栏闭合时，用户可把该段代码送进应用内 WebView 预览。JavaScript 片段没有「运行」入口，模型写出的脚本要被求值，只能靠模型主动调用本地工具 `eval_javascript`。围栏闭合门控与预览入口属于渲染层，细节见 [消息渲染器调查笔记](../消息渲染器/RikkaHub-消息渲染器调查笔记.md)。
- **唯一的语言运行时是本地工具。** `eval_javascript` 由 QuickJS 在应用进程内提供 ES2020 求值，无 DOM、无 Node API、无宿主桥；每次调用新建上下文，捕获 console 输出并连同最后一个表达式的值回填为工具结果文本。它是模型驱动的工具调用，不产生可交互、可再次运行的对象。
- **生成媒体分化成两条互不相通的路径。** 模型经服务端内置工具直接产出的图片，在流中还原为图片 part，生成结束时由输出转换器压缩写入 `filesDir/upload`，再随消息 JSON 持久化；独立的图片生成页把 PNG 写入 `filesDir/images` 并额外登记到 Room 的画廊表。画廊记录与聊天消息中的图片没有互引关系。两条路径分别见 [会话与消息管理调查笔记](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md) 与 [媒体创作调查笔记](../媒体创作/RikkaHub-媒体创作调查笔记.md)。
- **工作区是唯一具备「读写—再读回」闭环的对象面。** 在助手绑定工作区且 Rootfs 就绪时，模型获得读文件、写文件、改文件、跑 shell 四个工具，可直接在 Rootfs 内落盘、用统一 diff 回显改动、再读回文件。这是本项目中最接近「可编辑工作区」的实现，但对象是文件，不是模型输出。

能力等级判断（按指南谱系，同时保留多等级）：主体处于 **G0–G1**（格式化回复与可单独查看/复用的富静态结果：图片、表格、Mermaid、LaTeX）；`html/svg` 代码块预览与 web-ui 工作台预览构成 **G3 的窄实现**（用户可把片段放进 WebView/iframe 实际运行，但无对象 ID、无能力桥、无运行状态持久化）；工作区文件工具构成 **G4 的局部实现**（模型可对同一文件连续读写改）；声明式交互对象（G2）与桌面活对象（G5）本次未找到。

## 必查问题逐项对照

1. **触发与输出协议**：无 artifact 协议；触发来自模型自由文本（Markdown 围栏）与工具调用（JSON Schema 参数）。半截流的请求侧语义见 [对话请求与上下文调查笔记](../对话请求与上下文/RikkaHub-对话请求与上下文调查笔记.md)。
2. **对象模型**：输出对象只有消息 part 家族；无稳定对象 ID、无版本、无能力声明。图片的稳定标识是文件路径或画廊表主键，两侧不互引。
3. **生成与更新链**：逐分片合并 part，整段重渲染；无 AST 节点 patch，也没有把 diff/patch 应用到输出的通道。分片合并见会话与消息管理笔记。
4. **投影表面**：消息内联、消息内嵌 WebView、全屏 WebView 页、系统分享目标、局域网 web-ui 工作台侧栏；同一对象可有多个投影，但运行状态不互通。渲染管线见消息渲染器笔记。
5. **表现与运行时**：静态 Markdown/高亮/KaTeX/Mermaid 由消息渲染器负责；本类目承载的执行环境见下文能力矩阵。
6. **交互和事件**：用户侧按钮与页签、WebView 控制台日志、Mermaid 导出桥均由渲染器实现；预览高度不持久化，重开重建。
7. **编辑与协作**：用户编辑消息全文并重生成，消息分支提供版本语义；无对象级 diff 接受/拒绝、无 CRDT。
8. **能力与执行位置**：QuickJS 在应用进程内；shell 在 Rootfs（PRoot）内；预览 WebView 在系统 WebView 内，脚本默认开启且无能力桥（Mermaid 导出除外）。
9. **持久化与版本**：消息 part JSON + 输出文件 + 画廊表；无对象级版本。持久化主干见会话与消息管理笔记。
10. **模型回流**：模型看不到对象列表，不感知预览状态；能读回工作区文件，能从历史消息看到自己写过的代码。
11. **生命周期与性能**：WebView 释放、内容缓存过期、临时预览文件删除、控制台日志限长；无对象级配额。
12. **验证体系**：工作区与 videogen 有 JVM 单测；未见针对预览 WebView 实际行为的自动化验证。

## 输出对象模型

当前快照不接受「声明一个对象类型并更新它」的输出协议。模型输出被解析为 Markdown 文本，渲染层再按代码围栏或原始 HTML 决定展示方式；没有任何字段声明「这是一段可运行代码」或「这是一个可编辑对象」。若把「对象」定义为可单独寻址、可继续操作的结果实体，则只有消息 part 与文件两类；part 家族的完整定义与合并规则归 [会话与消息管理调查笔记](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)。

part 家族中与本类目最相关的一个成员是 `ServerTool`（`ai/src/main/java/me/rerere/ai/ui/UIMessagePart.kt:168-180`）：它用通用 JSON 承载服务端工具的输入输出与进行/完成/失败状态，专门表示「Provider 在服务端执行、客户端不参与审批」的调用，是服务端图片生成的载体。与之相对，本地工具由名称、描述、JSON Schema 参数与执行函数声明，是否启用由助手配置决定。图片生成能力本身挂在模型定义上，作为 Provider 侧内置工具枚举（`ai/src/main/java/me/rerere/ai/provider/Model.kt:42-57`），不是应用内工具。

媒体对象在数据层另有 `GenMediaEntity`（自增主键、相对路径、模型、提示词、创建时间、类型与源图路径，`app/src/main/java/me/rerere/rikkahub/data/db/entity/GenMediaEntity.kt:7-27`），只服务独立图片生成页，与聊天消息里的图片 part 无外键或引用关系。

检索 artifact/canvas/notebook 类输出协议、声明式 UI schema 渲染（G2）、生成对象级版本与单文件包导入导出，范围覆盖全仓 Kotlin/TSX/资源 HTML，关键词含 artifact、canvas、notebook、sandbox、iframe、webview、eval、exec、spawn、writeFile 等；未纳入 `document/` 的第三方 MuPDF 与 `.agents/` 技能资料，以上能力本次未找到。

## 运行环境与执行位置能力矩阵

各运行环境的能力与位置对照如下。四类环境都不为生成结果提供对象身份，能力差异只在执行位置与权限边界。

| 环境 | 执行位置 | 权限与边界 | 定位 |
| --- | --- | --- | --- |
| 本地 JavaScript 工具 | 应用进程内 | QuickJS 求值 ES2020；描述中明确无 DOM、无 Node API；每次调用新建上下文，注入 console 四级别捕获；默认免审批 | `app/src/main/java/me/rerere/rikkahub/data/ai/tools/local/JavascriptTool.kt:16-73` |
| 预览 WebView | 系统 WebView | 脚本默认开启、允许 DOM 存储；无 CSP、无来源白名单、无 `postMessage` 桥（除渲染层自用的 Mermaid 导出接口） | `app/src/main/java/me/rerere/rikkahub/ui/components/webview/WebView.kt:98-138` |
| 工作区 shell | Rootfs（PRoot） | `/dev`、`/proc`、`/sys` 拒绝直接文件读取，只能经 shell 访问；`/workspace`、`/tmp`、`/skills` 之外写入需审批 | `workspace/src/main/java/me/rerere/workspace/WorkspaceManager.kt:121-146,191-219` |
| web-ui 工作台 iframe | 内嵌 Ktor 服务器托管的 React 页面 | `<iframe sandbox="allow-scripts allow-same-origin">`，同时允许脚本与同源，预览语言与资源加载归渲染层 | `web-ui/app/components/workbench/workbench-host.tsx:163-168` |

预览 WebView 的承载范围（Mermaid、代码与 HTML 预览）、脚本接口种类、资源来源与门控规则，以及 Mermaid 的 SVG→PNG 导出桥，均属渲染层，归 [消息渲染器调查笔记](../消息渲染器/RikkaHub-消息渲染器调查笔记.md)。本类目在此只关心它作为执行位置的能力面：脚本默认开启、无 CSP、无来源白名单、无 `postMessage` 桥，模型生成的页面可自行发起网络请求（`app/src/main/java/me/rerere/rikkahub/ui/components/webview/WebView.kt:98-138`）。

内嵌服务器的启动、端口、令牌与路由，以及 web-ui 的托管方式，归 [外部执行体与应用协作调查笔记](../外部执行体与应用协作/RikkaHub-外部执行体与应用协作调查笔记.md)。

视频生成模块当前未接入、TTS 不产生媒体资产：这两条产品侧结论归 [媒体创作调查笔记](../媒体创作/RikkaHub-媒体创作调查笔记.md)；本类目只确认它们不产生可寻址的生成对象。

## 编辑、diff、版本与协作

生成结果没有对象级编辑、接受/拒绝、撤销、分支或协作机制。用户侧编辑改的是消息全文，保存后触发重生成；消息分支用「同一节点下多条备选消息 + `selectIndex`」表达版本，属于消息版本而非输出对象版本，实现见会话与消息管理笔记。对代码块、HTML 预览与生成图片而言，模型要「改」只能重新生成整条消息。

模型侧唯一的编辑能力落在工作区文件上：替换工具按「精确 → 行首尾空白容错 → 块锚点」逐级降级匹配，并把生成的统一 diff 写入工具结果的元数据供 UI 渲染，明确不随工具结果发给 API（`app/src/main/java/me/rerere/rikkahub/data/ai/tools/WorkspaceTools.kt:137-201`）。这是「模型修改 → 展示 diff → 再读回」的完整小闭环，但编辑对象是用户/模型共享的文件，不是某条生成结果。

生命周期治理同样没有对象级面。WebView 释放、预览内容缓存的 7 天过期、控制台日志限长、生成中间帧清理都属于渲染器或页面自身的运行期资源策略（见消息渲染器笔记）；本类目未找到对象级的数量配额、暂停/冻结或可见性驱动的卸载机制，多预览场景仅受 Compose 与 WebView 的常规资源约束。

## 未验证事项

- WebView 中模型 HTML 的实际网络行为、脚本执行效果与安全边界（`allowFileAccess` 等默认值随 Android API 版本变化，需要设备实测）。
- 承载 Mermaid 与 html/svg 的预览路径在无外网环境下的降级表现（渲染层自有资源来源见消息渲染器笔记）。
- QuickJS 上下文是否在求值后被显式释放；`JavascriptTool.kt` 只创建上下文并求值，未见到关闭调用，是否依赖 GC 需要运行验证。
- 聊天图片 part 在本地文件化之后，再次发送给 Provider 时的编码路径（`isValidToUpload` 只要求 URL 非空，实际是否转回 base64 由各 Provider 组装逻辑决定）。
- 内部测试覆盖：`videogen` 有 Provider 解析单测，`workspace` 有路径解析与安装器测试；未找到覆盖预览 WebView 行为、消息图片持久化或 html/svg 预览门控的自动化用例。

## 关键源码索引

- 输出对象模型与媒体对象：`ai/src/main/java/me/rerere/ai/ui/UIMessagePart.kt:50-217`、`ai/src/main/java/me/rerere/ai/provider/Model.kt:42-57`、`app/src/main/java/me/rerere/rikkahub/data/db/entity/GenMediaEntity.kt:7-27`
- 本地 JavaScript 工具：`app/src/main/java/me/rerere/rikkahub/data/ai/tools/local/JavascriptTool.kt:16-73`、`app/src/main/java/me/rerere/rikkahub/data/ai/tools/local/LocalToolOption.kt:7-14`、`app/src/main/java/me/rerere/rikkahub/data/ai/tools/local/LocalTools.kt:31-56`
- 工具装配与审批默认值：`app/src/main/java/me/rerere/rikkahub/data/ai/tools/ChatToolFactory.kt:38-95`、`ai/src/main/java/me/rerere/ai/core/Tool.kt`
- 预览 WebView 运行环境：`app/src/main/java/me/rerere/rikkahub/ui/components/webview/WebView.kt:98-150`（承载范围、资源映射与导出桥见消息渲染器笔记）
- 工作区沙箱与文件工具：`app/src/main/java/me/rerere/rikkahub/data/ai/tools/WorkspaceTools.kt:24-34,62-270,399-428`、`workspace/src/main/java/me/rerere/workspace/WorkspaceManager.kt:121-146,191-219,245-258`
- 内嵌服务器与 web-ui 工作台：`web/src/main/java/me/rerere/rikkahub/web/Entry.kt:18-43`、`app/src/main/java/me/rerere/rikkahub/web/WebServerManager.kt:53-108`
- 视频生成模块（当前未接入）：`videogen/src/main/java/me/rerere/videogen/provider/VideoGenerationManager.kt:15-69`、`app/build.gradle.kts:290`
