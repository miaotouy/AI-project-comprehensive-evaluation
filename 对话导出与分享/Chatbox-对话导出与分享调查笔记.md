# Chatbox 对话导出与分享调查笔记

> 调查对象：`E:\works\git\chatbox`
>
> 调查更新日期：2026-08-14
>
> 代码快照：`81571269addb6bafb589a920b2883f1e1e084fd1`（分支：`main`）
>
> 调查方式：静态源码调查（未运行应用）；通读导出弹窗、共享格式化器、HTML 服务端静态渲染、平台 exporter 接口、备份 ZIP v2 导出/导入与往返测试；未运行桌面/Web/移动端做视觉、下载与离线打开验证
>
> 调查范围：会话级对话导出（Markdown/TXT/HTML）的入口、内容口径、附件策略与富内容保真；备份导出的边界与往返；VibeDrop 发布与系统分享面板的边界归属；平台交付差异；不覆盖备份内部 schema 全量、RAG 索引重建、Chat UI 菜单可用性与聊天现场渲染器细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Chatbox 的对话导出是一个轻量单弹窗能力：顶部工具栏的 "Export Chat" 打开弹窗，只提供范围（当前线程 / 全部线程）与格式（Markdown / TXT / HTML）两个下拉，点击后立即生成文件并关闭，没有预览、编辑、剪贴板或版本历史。三种格式共用同一套基于 `contentParts` 的抽取逻辑（`src/shared/utils/chat-export.ts` 与 `src/renderer/lib/format-chat.tsx`），内容口径完全一致：text 正文、info 文本、tool-call 结构化工具卡（args/result）、图片占位或内联；reasoning、agent-mode-suggestion 和分叉分支（`messageForksHash`）本次未发现任何导出处理，直接跳过。

HTML 导出用 `ReactDOMServer.renderToStaticMarkup` 复用聊天现场同一套 Markdown 组件做离屏静态渲染，不快照当前界面：Shiki 同步高亮可以进入静态输出，Mermaid 等异步渲染内容在静态导出中不落地；受管图片从 IndexedDB 读 blob 内联为 base64 data URL，远程图片保持外部引用；样式依赖 Tailwind CDN 运行时、KaTeX CDN CSS 和 chatboxai.app 图标域，离线打开不完整。标题 `sessionName`、线程名与远程图片 URL 直接拼接进 HTML 且未转义。

分享链路分为三块且互不关联：① 本地文件交付（本次核心）；② 设置页整库备份 ZIP v2（可往返导入，属备份恢复边界）；③ VibeDrop 静态页发布（发布对象限于聊天内可渲染代码块的 HTML 内容，会话本身不进入该链路，主体归属生成式输出类目）。会话层面的公开链接分享、图片长图分享和 PDF 导出本次未找到。

## 系统边界与完整主链

```text
当前 Session（session.messages + 可选 session.threads 历史线程）
  -> Toolbar "Export Chat" -> ExportChat 弹窗（scope + format 两个下拉）
  -> exportSessionChat(sessionId, scope, format)
  -> exportChat() 组装线程
  -> formatChatAsMarkdown / formatChatAsTxt（shared 层，纯字符串）
     或 formatChatAsHtml（renderer 层，renderToStaticMarkup）
  -> platform.exporter.exportTextFile(`${session.name}.${ext}`, content)
  -> Web/Desktop：<a download> anchor 下载；Mobile：writer 分块写 Documents / Cache+系统选择器
```

与备份和发布的关系：备份走独立的 `exportBackupArchive`（ZIP v2 流式导出，`routes/settings/general.tsx` 设置页入口），导入走 `importBackupArchive` / `importLegacyJsonBackup`；VibeDrop 发布走 `publishToVibedrop`（`packages/vibedrop.ts`）。三者抽取口径、交付物和存储位置各自独立。

## 1. 入口、用户目标与导出源

- 入口只有一处：会话顶部工具栏的 ActionMenu 菜单项 "Export Chat"（`src/renderer/components/layout/Toolbar.tsx:136-140`，窄屏布局同样存在 `:202-205`），经 `NiceModal.show('export-chat')`（`Toolbar.tsx:45-47`，注册于 `modals/index.tsx:29`）打开 `ExportChat` 弹窗。本次未在其他位置（消息菜单、会话列表、命令行）找到导出入口。
- 弹窗仅两个下拉：Scope（`all_threads` / `current_thread`）与 Format（`Markdown` / `TXT` / `HTML`），默认 HTML + 全部线程（`src/renderer/modals/ExportChat.tsx:15-16,48-65`）。弹窗内固定显示警示文案 "Exports are for viewing only. Use Settings → Backup if you need a backup you can restore."（`ExportChat.tsx:43-47`），明确区分"阅读导出"与"备份"两种用户目标。
- 点击 Export 后 `void exportSessionChat(...)` 不等待即关闭（`ExportChat.tsx:23-30`）；`exportSessionChat` 从 chatStore 取 Session 后转交 `exportChat`（`src/renderer/stores/session/export.ts:5-11`）。
- 导出源为完整 Session 对象（`src/renderer/stores/sessionHelpers.ts:947-966`）：`current_thread` 只导出 `session.messages`（活动线程）；`all_threads` 先把 `session.threads`（历史线程）按原数组顺序放入，再把主线程（标题取 `threadName || name`）追加在最后。`session.threads` 是上下文压缩/刷新线程时归档的历史线程（见 `stores/session/threads.ts` 的 `compressAndCreateThread` 等），会话分叉 `messageForksHash` 不在导出范围——分叉分支本次确认不进入任何导出格式（`exportChat` 组装处只读 `threads` 与 `messages`）。
- 顺序：线程按 `threads` 数组顺序，消息按 `messages` 数组顺序，无排序或重排选项。

## 2. 范围选择、内容口径与字段过滤

三种格式共用 `contentParts` 循环（`src/shared/utils/chat-export.ts:91-224`、`src/renderer/lib/format-chat.tsx:35-106`），按 part 类型处理：

| part 类型 | Markdown / TXT | HTML |
|---|---|---|
| `text` | 累积进缓冲区，消息体整体包进 ``` 围栏（TXT 直接拼接） | renderToStaticMarkup 渲染共享 Markdown 组件 |
| `image` | 占位符 `[image]` | 受管图（storageKey）读 blob 内联 base64；远程图保持 URL 引用 |
| `tool-call` | `renderToolCallMarkdown` / `renderToolCallTxt`，按 toolCallId 去重 | `renderToolCallHtml` 卡片（escapeHtml 后放入 pre） |
| `info` | 文本并入正文 | 文本并入正文 |
| `reasoning` | 跳过 | 跳过 |
| `agent-mode-suggestion` | 跳过 | 跳过 |

- reasoning 排除可从两处确认：`contentParts` 循环没有 reasoning 分支（`chat-export.ts:110-137`、`format-chat.tsx:50-91`）；回退路径 `getMessageText(msg)` 的 `includeReasoning` 默认 `false`（`src/shared/utils/message.ts:5-11`）。这与聊天现场"思考块可见"形成口径差。
- 工具调用：`collectToolCallSummaries`（`chat-export.ts:15-31`）只合并 `args`/`result` 内联字段；超大工具结果走 blob 溢出的 `resultStorageKey`（schema 见 `src/shared/types/session.ts:204-205`）不会出现在导出中。args/result 经 `stringifyDataForExport` 做 JSON 识别与 2 空格美化（`chat-export.ts:46-55`）。
- system 角色消息原样导出（标题 `**system**:` / `SYSTEM:`），默认提示词等 system 消息会出现在交付物中；无任何脱敏、密钥扫描或按角色过滤开关。
- 附件与链接：附件只导出文件名列表（`getAttachmentNames`，`chat-export.ts:64-66`）；`msg.links`（已解析链接）在三种格式中均未处理，本次未找到任何引用。
- 空消息（仅 tool-call 完成态的消息）仍会输出一个带"角色标题"的空块（消息级循环无空过滤，`chat-export.ts:109-148`）。

## 3. 附件、资源与离线封装

- Markdown/TXT：图片为 `[image]` 占位，附件为文件名列表，正文无图片数据；文件可离线阅读，但内容不可见。
- HTML：受管图片从 `storage.getBlob(storageKey)`（IndexedDB blob 存储）读出，经 `base64.parseImage` 拼成 `data:` URL 内联（`format-chat.tsx:74-89`）；读取失败时静默产出空 `src`（`url=''`，无降级占位）。旧式 `p.url` 图片保持原始外部 URL 引用，不做代理或转码。附件仍只有文件名列表，链接不导出。
- HTML 离线性：页面引 `https://cdn.tailwindcss.com`（运行时 JIT 生成样式，含 typography 插件）、jsdelivr KaTeX CSS 与 chatboxai.app 图标（`format-chat.tsx:107-141`），因此断网打开时布局样式、数学公式样式与图标缺失；正文文本本身随文件携带。CDN 脚本在打开文件时执行，属于加载期远端脚本依赖（安全见第 9 节）。
- 备份 ZIP v2 才是资源级封装：`resources/` 目录收集消息图片、附件解析/原文 blob、离线工具结果、头像与背景图（`src/renderer/packages/backup/resources.ts:19-120`），且遍历范围含分叉分支（`resources.ts:88-98`），比对话导出的抽取范围更完整。

## 4. 格式、schema 与往返能力

- `ExportChatFormat = 'Markdown' | 'TXT' | 'HTML'`（`src/shared/types.ts:20-22`）。会话级 JSON、PDF、PNG 导出本次未找到（全仓搜索 `html-to-image`/`html2canvas`/`toPng`/`screenshot` 均无会话导出用途命中；`package.json` 无相关依赖）。
- Markdown 输出是"带围栏的线性文档"：一级标题为会话名，每线程 `## N. 线程名`，每条消息以 `**role**:` 开头、正文包进 ``` 围栏，结尾固定追加 Chatbox 品牌 HTML 片段（`chat-export.ts:151-158`）。TXT 是同一抽取逻辑的纯文本变体。
- 三种格式都不可往返：无 schema、无消息 ID/时间戳/模型/分支元数据，只保留角色与内容投影，无法据此恢复 Chatbox Session。
- "备份"才是可往返的导出：ZIP v2 带 `manifest.json`（`format: 'chatbox-backup'`、`formatVersion: 2`，`src/renderer/packages/backup/types.ts:4-5,65-91`），含 session JSON、资源、SHA-256 校验、双向映射与统计；导入分"读取暂存 → 完整校验 → 事务提交"三阶段（见 `docs/technical/data-backup.md`，与实现一致）。`backup-roundtrip.test.ts`（890 行）用内存存储做导出→导入闭环断言。旧版单 JSON 备份仍可导入（`general.tsx:792-801` 走 `importLegacyJsonBackup`）。
- 遗留 UI：`src/renderer/pages/SettingDialog/AdvancedSettingTab.tsx` 仍是旧的单 JSON 备份/恢复界面（含 `__exported_items` 字段），但本次全仓搜索未发现任何引用，属于死代码；活动入口是 `src/renderer/routes/settings/general.tsx` 的 `ImportExportDataSection`。

## 5. 分享稿编辑、编排与预览

不适用（本次未找到独立分享稿工作台）。ExportChat 弹窗没有预览、内容开关、编辑或比较能力；选择范围与格式后直接生成并下载。HTML 生成与下载在同一次点击内完成（`ExportChat.tsx:23-30` → `sessionHelpers.ts:962-964`），中间没有可停留的中间表达对象。dev 构建下有 "View Session JSON" 菜单（`Toolbar.tsx:141-149`）打开 `JsonViewer`，仅查看与复制原始 Session JSON，无文件导出、无预览意义。

## 6. 图片、HTML、PDF 与富内容生成

- 图片（E3）：本次未找到把对话渲染成 PNG/JPEG 的能力；`PictureDialog`（`src/renderer/pages/PictureDialog.tsx:48-67`）与 `ImageViewer.downloadPicture`（`src/renderer/components/ImageViewer.tsx:30-55`）只是把会话里已有图片下载成文件（指南界定范围外，模型图片生成/原始附件下载）。
- PDF：本次未找到（导出端无打印/PDF 管线，`src/main` 的 pdf 相关仅为文档解析 `parsePdf`）。
- HTML：独立渲染器路线。`formatChatAsHtml` 用 `ReactDOMServer.renderToStaticMarkup` 静态渲染共享 `Markdown` 组件，传 `hiddenCodeActions`（隐藏复制/预览/发布按钮，测试 `format-chat.test.tsx:32-46` 断言无 `<button>`）、`defaultCollapsed={false}`（关闭代码折叠）、`forceColorScheme="dark"`（导出页无主题，固定深色代码块，源码注释 `format-chat.tsx:67`）。
  - 富内容保真（基于静态代码的推断）：Shiki 走 `highlightSync`（`components/Markdown.tsx:486-501`）可同步进静态输出；不支持同步的语言在静态渲染中不会触发 `useEffect` 异步升级，回退为纯 `<code>`（`Markdown.tsx:514-521`）。Mermaid 是 `useEffect` 驱动的客户端渲染（`components/Mermaid.tsx:19-62`，初态 `svgCode=''`），静态导出得到的是空占位，图源文本也不进入页面——推断为"Mermaid 不随 HTML 导出"。SVG 代码块（`svg`/`xml`/`html` 且以 `<svg` 开头）由 `SVGPreview` 同步转 data URL 图片（`Mermaid.tsx:161-177`、`Markdown.tsx:322-327`），可进入静态输出。KaTeX 为 rehype 同步插件，样式靠导出的 CDN CSS。
  - 样式缺口（推断）：导出页只加载 Tailwind CDN 与 KaTeX CSS，Markdown 组件输出的 Mantine 类名与 `shiki-code.css` 类名（`Markdown.tsx:72` 应用内引入）在导出文件中无对应样式，代码块底色/行号样式可能丢失；需运行验证。
  - 文件名：`${session.name}.html`（`sessionHelpers.ts:964`），无非法字符清洗，跨平台文件名行为未验证。

## 7. 生成历史、版本与持久化

不适用（本次未找到）。每次导出生成一个全新文件，无版本列表、历史比较或再生成记录；应用内不持久化任何导出记录。VibeDrop 发布有按 `uniqueId` 复用的 slug 更新语义（见下节），但那是发布对象而非会话导出。

## 8. 分享载体、访问控制与撤销

- 会话导出：本地文件是唯一载体（Web/Desktop anchor 下载、Mobile 系统写入），无链接、无远端对象。Web 端备份完成后可选系统 Share Sheet 交付 ZIP 文件（`web_file_share.ts:6-22`，`general.tsx:646-669`），仅限备份文件。
- VibeDrop 发布（`src/renderer/modals/VibedropPublish.tsx` + `src/renderer/packages/vibedrop.ts`）：把聊天中可渲染代码块（HTML/XML/SVG/JS 等，`Markdown.tsx:583-595,646-660`）的 HTML 内容发布为静态页。发布前需登录 Chatbox 账号并签发 per-user key（`issueVibedropKey`，缓存于设置 `vibedropPublishKey` 且按账号 email 绑定，`vibedrop.ts:131-148`）。可见性仅 `unlisted` / `public` 两档，同名 slug 可更新（更新失败会提示 slug 不再归属）；发布记录按会话存最近 20 条（`vibedrop.ts:165-190`）；管理入口在第三方站点 app.vibedrop.cc。删除、过期、克隆等其余治理由服务端承担，本地无对应调用。该能力只发布代码块 HTML，不发布会话，主体归属生成式输出与运行时类目，本类目只记录边界。
- 会话级公开链接分享（E4）：本次未找到（无分享 API 调用、无 URL 生成代码）。

## 9. 隐私、安全与内容治理

- 导出内容无过滤：system 提示词、工具 args/result（含可能的敏感数据）原样进入三种格式；reasoning 恰好被跳过。备份侧有明确的密钥脱敏（`src/shared/utils/backup.ts:19-74`：不勾选 "API KEY & License" 时移除提供商凭据、搜索密钥、MinerU token、VibeDrop 发布密钥、MCP env/headers；license 运行时状态无论勾选与否都剔除），对话导出没有对应机制。
- HTML 转义缺口（源码直接确认）：`sessionName` 直接拼入 `<title>` 与 `<h1>`（`format-chat.tsx:112,125`），`thread.name` 拼入 `<h2>`（`:39`），旧式图片 `p.url` 拼入 `src="..."`（`:86-88`），均未转义；消息正文经 React 默认转义，工具参数/附件名经 `escapeHtml`（lodash）。会话名或 URL 含特殊字符时可注入导出文件 DOM（自打开文件的 self-XSS 风险，需运行确认浏览器行为）。
- 外部资源：导出 HTML 依赖 Tailwind/KaTeX CDN 脚本与 chatboxai.app 图标域，打开文件时加载远端代码；受管图片内联 data URL 无跨域问题，远程图片 URL 保持原样引用。
- 备份导入有完整安全限制（路径穿越、重复 entry、大小与压缩比上限、manifest 校验，`types.ts:93-153` 与 `docs/technical/data-backup.md` 一致），导入后强制重启生效。

## 10. 性能、失败恢复与测试

- 生成是纯内存拼接：Markdown/TXT 单字符串构建；HTML 逐消息异步读取 blob 并拼接（`format-chat.tsx:35-106`），无大小上限、无分页、无分段写入；超长会话与超大图片的内存/耗时未验证。
- 失败路径：`exportSessionChat` 被 `void` 调用且无 catch（`ExportChat.tsx:27`），会话加载失败或 HTML 生成抛错时无任何用户反馈；图片 blob 读取失败静默变空 `src`。Web 下载用 `<a download>` + ObjectURL，1 秒后 revoke（`web_exporter.ts:14-40`）。桌面平台复用 `WebExporter`（`desktop_platform.ts:33`），main 进程本次未找到 `will-download` 处理，Electron 默认下载行为（保存位置、是否弹框）未运行验证。
- 移动端 `MobileExporter`/`AndroidFilterWriter` 有完整的失败降级与取消收口（Documents 写入失败 → Cache + 系统选择器，日志分级，`filter_writer.ts:656-811`），并有单测覆盖。
- 测试：`format-chat.test.tsx`（HTML 导出无交互按钮）、`backup-roundtrip.test.ts`（ZIP 往返）、`web_exporter.test.ts`、`filter_writer.test.ts`、`web_file_share.test.ts`、`VibedropPublish.test.tsx` 存在；对话导出的 Markdown/TXT 内容断言测试本次未找到。
- 取消：备份导出/导入支持 AbortController 取消（`general.tsx:674-753`）；会话导出无取消。

## 11. 设计取舍与已确认边界

- 会话导出刻意轻量：一个弹窗、两个下拉、三格式、零预览零历史，定位"仅阅读交付"；弹窗文案把可恢复性明确推给 Settings → Backup，实现上两者也确实完全分离（格式、抽取范围、资源策略都不一致）。
- 三种格式共享同一抽取管线，保证口径一致；HTML 是唯一带资源内联的格式，通过复用聊天现场 Markdown 组件进行静态渲染，因此富内容保真取决于该组件的同步渲染能力。
- 导出与备份的抽取范围差异是有意边界：对话导出不含分叉分支、链接与工具结果 blob；备份覆盖分叉且资源级封装，但只在设置页提供。
- reasoning 与 agent-mode-suggestion 在导出端静默丢弃，与聊天现场可见性不一致；导出端没有任何"包含思考"的开关（与 NextChat 的 thinking 全文导出形成对照）。
- 分享链路刻意本地化：无账户、无远端会话快照；唯一远端发布（VibeDrop）只处理代码块网页。
- 遗留代码：旧的单 JSON 备份 UI（`SettingDialog/AdvancedSettingTab.tsx`）未被引用；文档 `docs/technical/data-backup.md` 与当前 ZIP v2 实现一致，未发现文档-实现矛盾。

## 12. 未验证事项

- HTML 导出的实际离线打开效果：Tailwind CDN 失效时的样式、KaTeX 渲染、Mermaid 空占位、Mantine/Shiki 样式缺失程度——均为静态推断，需运行验证。
- 桌面端（Electron）anchor 下载的实际保存位置与是否弹窗（无 `will-download` 处理）；Web 端浏览器对含非法字符文件名（`${session.name}.html`）的清洗行为。
- 会话名/线程名/远程图片 URL 未转义注入导出的实际浏览器表现与自 XSS 可行性。
- 超长会话、超大图片的 HTML 生成内存与耗时；移动端 Documents/Share Sheet 的实际行为（源码有降级链，未运行）。
- 远端图片在导出 HTML 中的可见性（部分外链图源有防盗链时）。
- 本地存储 blob 读取失败在 HTML 导出中的静默空 `src` 是否真实发生（依赖索引数据完整）。

## 13. 关键源码索引

- `src/renderer/modals/ExportChat.tsx`（弹窗：范围/格式下拉、警示、立即导出）
- `src/renderer/components/layout/Toolbar.tsx`（"Export Chat" 唯一入口）
- `src/renderer/stores/session/export.ts`、`src/renderer/stores/sessionHelpers.ts`（`exportSessionChat` / `exportChat` 主链）
- `src/shared/utils/chat-export.ts`（Markdown/TXT 格式化、工具卡、附件名）
- `src/renderer/lib/format-chat.tsx`（HTML 静态渲染、图片内联、转义缺口）
- `src/renderer/components/Markdown.tsx`、`src/renderer/components/Mermaid.tsx`（导出端共享渲染、Shiki 同步/异步、Mermaid 异步、VibeDrop 入口）
- `src/renderer/platform/web_exporter.ts`、`src/renderer/platform/interfaces.ts`、`src/renderer/platform/desktop_platform.ts`、`src/renderer/platform/mobile_exporter.ts`、`src/renderer/platform/filter_writer.ts`（平台交付与降级）
- `src/renderer/routes/settings/general.tsx`（备份导出/导入/Share Sheet，与导出隔离）
- `src/renderer/packages/backup/`（types.ts 格式 v2、export-backup.ts、import-backup.ts、resources.ts、backup-roundtrip.test.ts）
- `src/renderer/packages/vibedrop.ts`、`src/renderer/modals/VibedropPublish.tsx`（代码块 HTML 发布边界）
- `src/shared/utils/message.ts`（`getMessageText` 默认排除 reasoning）
- `src/shared/types/session.ts`、`src/shared/types.ts`（contentParts/线程/导出类型 schema）
