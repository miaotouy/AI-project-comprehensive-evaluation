# Chatbox 对话导出与分享调查笔记

> 调查对象：`https://github.com/chatboxai/chatbox`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`d17455c5ca8fd3ff44385c6d4d2118599e4c970f`（分支：`main`）
>
> 调查方式：静态源码调查（未运行应用）；通读导出弹窗、共享格式化器、HTML 服务端静态渲染、平台 exporter 接口、备份 ZIP v2 导出/导入与往返测试；未运行桌面/Web/移动端做视觉、下载与离线打开验证
>
> 调查范围：会话级对话导出（Markdown/TXT/HTML）的入口、内容口径、附件策略与富内容保真；备份导出的边界与往返；VibeDrop 发布与系统分享面板的边界归属；平台交付差异；不覆盖备份内部 schema 全量、RAG 索引重建、Chat UI 菜单可用性与聊天现场渲染器细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Chatbox 的对话导出仍是轻量单弹窗能力，但范围已增加“导出全部分支”。Markdown/TXT 会把每个消息 fork 展开为带 Branch N/M 标题的线性线程；HTML 则保存分支数据并嵌入本地脚本，读者可在导出文件中用上一支/下一支按钮切换，重建与应用内相同的可见尾部。reasoning 与 agent-mode-suggestion 仍不进入交付物。

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

与备份和发布的关系：备份走独立的 ZIP v2 流式导出（设置页入口 `routes/settings/general.tsx`），导入支持新版与旧版单 JSON 两种（`importBackupArchive`/`importLegacyJsonBackup`）；VibeDrop 发布走 `publishToVibedrop`（`packages/vibedrop.ts`）。三者抽取口径、交付物和存储位置各自独立。

## 1. 入口、用户目标与导出源

- 导出入口只有一处：会话顶部工具栏的 ActionMenu 里有一项 "Export Chat"，宽屏与窄屏布局各渲染一次，实现见 `src/renderer/components/layout/Toolbar.tsx:45-47,136-140,202-205`；消息菜单、会话列表和命令行本次都未找到导出入口。
- 点击该菜单项后，NiceModal 按 `export-chat` 注册项打开导出弹窗 `ExportChat`，注册位置见 `src/renderer/modals/index.tsx:29`。
- 弹窗只有范围与格式两个下拉：范围可选当前线程或全部线程，格式可选 Markdown、TXT、HTML，默认全部线程加 HTML。弹窗内固定显示一条警示，说明导出仅供查看，需要可恢复的备份请走设置页 Backup。默认值与文案见 `src/renderer/modals/ExportChat.tsx:15-16,43-47,48-65`。
- 点击 Export 后弹窗立即关闭，不等待导出完成；导出函数先从行存储投影取出会话，再交给线程组装入口 `exportChat`，两处调用见 `src/renderer/modals/ExportChat.tsx:23-30` 与 `src/renderer/stores/session/export.ts:5-11`。
- 导出源是完整 Session。默认范围按当前线程或全部线程组装；启用全部分支后，Markdown/TXT 用共享层的 `expandMessageBranches` 把每条分叉展开成线性路径，HTML 则保留原始 `messageForksHash` 供文件内脚本切换。共享组装与 HTML 收集分别见 `packages/chatbox-core/src/backup-export/session.ts:47-71` 和 `src/renderer/lib/format-chat.tsx:169-385`。
- 顺序：线程按 `threads` 数组顺序，消息按 `messages` 数组顺序，无排序或重排选项。

## 2. 范围选择、内容口径与字段过滤

三种格式共用 `contentParts` 循环（`packages/chatbox-core/src/backup-export/session.ts:91-224`、`src/renderer/lib/format-chat.tsx:35-106`），按 part 类型处理：

| part 类型 | Markdown / TXT | HTML |
|---|---|---|
| `text` | 累积进缓冲区，消息体整体包进 ``` 围栏（TXT 直接拼接） | renderToStaticMarkup 渲染共享 Markdown 组件 |
| `image` | 占位符 `[image]` | 受管图（storageKey）读 blob 内联 base64；远程图保持 URL 引用 |
| `tool-call` | `renderToolCallMarkdown` / `renderToolCallTxt`，按 toolCallId 去重 | `renderToolCallHtml` 卡片（escapeHtml 后放入 pre） |
| `info` | 文本并入正文 | 文本并入正文 |
| `reasoning` | 跳过 | 跳过 |
| `agent-mode-suggestion` | 跳过 | 跳过 |

- 推理内容在导出时被丢弃，可以从两处实现确认：三种格式共用的内容分片循环里没有 reasoning 分支，回退取纯文本时 `getMessageText` 也只返回正文。定位见 `chat-export.ts:110-137`、`src/renderer/lib/format-chat.tsx:50-91` 与 `src/shared/utils/message.ts:5-11`。聊天现场把思考块展示给用户，导出物中这部分内容缺席，两处可见范围不一致。
- 工具调用只保留内联的参数与结果：摘要收集器合并这两个字段，超出阈值的工具结果已溢写到 blob（`resultStorageKey`），导出物里没有这部分内容；参数与结果经 JSON 识别后按 2 空格缩进美化。收集与美化见 `chat-export.ts:15-31,46-55`，溢出字段定义见 `src/shared/types/session.ts:204-205`。
- system 角色消息原样导出，Markdown 用 `**system**:`、TXT 用 `SYSTEM:` 作角色标题，默认提示词一类内容会直接出现在交付物里；导出端没有脱敏、密钥扫描或按角色过滤的开关。
- 附件只导出文件名列表（`getAttachmentNames`）；`msg.links` 中的已解析链接在三种格式里都没有处理，本次未找到任何引用。定位见 `chat-export.ts:64-66`。
- 只有工具调用完成态、没有正文的消息仍会输出一个空块，块内只有一个角色标题；消息级循环没有空内容过滤，见 `chat-export.ts:109-148`。

## 3. 附件、资源与离线封装

- Markdown 与 TXT 的正文里没有图片数据：图片位置写成 `[image]` 占位，附件只留文件名列表。文件可以离线打开，正文里的图片与附件内容则看不到。
- HTML：受管图片从 IndexedDB blob 存储读出（`storage.getBlob(storageKey)`），转成 `data:` URL 内联（`format-chat.tsx:74-89`）；读取失败时静默产出空 `src`，无降级占位。旧式 `p.url` 图片保持原始外部 URL 引用，不做代理或转码。附件仍只有文件名列表，链接不导出。
- HTML 离线性：页面引 `https://cdn.tailwindcss.com`（运行时 JIT 生成样式，含 typography 插件）、jsdelivr KaTeX CSS 与 chatboxai.app 图标（`format-chat.tsx:107-141`），因此断网打开时布局样式、数学公式样式与图标缺失；正文文本本身随文件携带。CDN 脚本在打开文件时执行，属于加载期远端脚本依赖（安全见第 9 节）。
- 备份 ZIP v2 才是资源级封装：`resources/` 目录收集消息图片、附件解析/原文 blob、离线工具结果、头像与背景图（`packages/chatbox-core/src/backup-export/session.ts:19-120`），且遍历范围含分叉分支（`resources.ts:88-98`），比对话导出的抽取范围更完整。

## 4. 格式、schema 与往返能力

- 导出格式只有 `ExportChatFormat` 一个联合类型，取值限定为 Markdown、TXT、HTML 三种，定义见 `src/shared/types.ts:20-22`。会话级 JSON、PDF、PNG 导出本次未找到：全仓用 html-to-image、html2canvas、toPng、screenshot 等截图关键词搜索，没有命中会话导出用途，`package.json` 里也没有相关依赖。
- Markdown 输出是一份带围栏的线性文档：会话名作一级标题，每个线程一个 `## N. 线程名` 小节，每条消息以 `**role**:` 开头并把正文包进代码围栏，文件末尾固定追加一段 Chatbox 品牌 HTML。结构见 `chat-export.ts:151-158`，TXT 沿用同一套抽取逻辑，只是输出纯文本。
- 三种格式都无法重新导入。交互 HTML 携带了消息 ID 与分叉结构，可以在导出文件里离线切换分支，但缺少稳定的导入 schema、完整的 Session 设置和资源映射，恢复不成 Chatbox 会话。
- 可往返的导出是 ZIP v2 备份：包内 `manifest.json` 声明格式标识 `chatbox-backup` 与版本 2，并包含会话 JSON、资源、SHA-256 校验、双向映射和统计；导入分读取暂存、完整校验、事务提交三个阶段，与 `docs/technical/data-backup.md` 的描述一致。格式声明见 `packages/chatbox-core/src/backup-export/types.ts:4-5,65-91`，往返闭环由 `backup-roundtrip.test.ts`（890 行）在内存存储上断言。
- 旧版单 JSON 备份仍有导入路径，走 `importLegacyJsonBackup`（`general.tsx:792-801`）。
- 遗留界面：`src/renderer/pages/SettingDialog/AdvancedSettingTab.tsx` 里还留着旧的单 JSON 备份/恢复界面，含 `__exported_items` 字段，但全仓搜索没有发现引用，属于死代码。当前生效的备份入口是 `src/renderer/routes/settings/general.tsx` 中的 `ImportExportDataSection`。

## 5. 分享稿编辑、编排与预览

不适用（本次未找到独立分享稿工作台）。ExportChat 弹窗没有预览、内容开关、编辑或比较能力；选择范围与格式后直接生成并下载。HTML 生成与下载在同一次点击内完成（`ExportChat.tsx:23-30` → `sessionHelpers.ts:962-964`），中间没有可停留的中间表达对象。dev 构建下有 "View Session JSON" 菜单（`Toolbar.tsx:141-149`）打开 `JsonViewer`，仅查看与复制原始 Session JSON，无文件导出、无预览意义。

## 6. 图片、HTML、PDF 与富内容生成

- 图片（E3）：本次未找到把对话渲染成 PNG/JPEG 的能力。`PictureDialog` 页面与图片查看器的下载方法只把会话里已有的图片存成文件，属于模型图片生成与原始附件下载，在指南界定的范围之外，见 `src/renderer/pages/PictureDialog.tsx:48-67`。
- PDF：本次未找到。导出端没有打印或 PDF 处理管线，`src/main` 中与 pdf 相关的代码只服务于文档解析（`parsePdf`）。
- HTML：走独立渲染器路线。`formatChatAsHtml` 用 `ReactDOMServer.renderToStaticMarkup` 把共享 Markdown 组件渲染成静态标记，并传入几项专用参数，见 `src/renderer/lib/format-chat.tsx:67` 起：
  - `hiddenCodeActions`：隐藏复制、预览、发布按钮，测试断言产物中没有 `<button>`（`format-chat.test.tsx:32-46`）；
  - `defaultCollapsed={false}`：代码块默认展开；
  - `forceColorScheme="dark"`：导出页不套用应用主题，代码块固定为深色。
  - 富内容保真（基于静态代码的推断）：
    - Shiki 走同步高亮，能够进入静态输出；不支持同步高亮的语言不会异步升级，回退成纯 `<code>`。两处逻辑见 `src/renderer/components/Markdown.tsx:486-501,514-521`。
    - Mermaid 由 effect 在客户端渲染，初始 `svgCode` 为空，静态导出只得到空占位，图源文本也不进页面，据此推断 Mermaid 图不随 HTML 导出，见 `src/renderer/components/Mermaid.tsx:19-62`。
    - SVG 代码块（语言为 svg、xml 或 html，且内容以 `<svg` 开头）由 `SVGPreview` 同步转成 data URL 图片，可以进入静态输出，见 `src/renderer/components/Mermaid.tsx:161-177` 与 `Markdown.tsx:322-327`。
    - KaTeX 是 rehype 的同步插件，公式样式依赖导出文件引入的 CDN CSS。
  - 样式缺口（推断）：导出页只加载 Tailwind CDN 与 KaTeX CSS，Markdown 组件输出的 Mantine 类名和 `shiki-code.css` 的类名在导出文件里没有对应样式，代码块底色与行号样式可能丢失，需运行验证；`shiki-code.css` 在应用内的引入见 `Markdown.tsx:72`。
  - 文件名：`${session.name}.html`，没有非法字符清洗，跨平台文件名行为未验证，见 `sessionHelpers.ts:964`。

## 7. 生成历史、版本与持久化

不适用（本次未找到）。每次导出生成一个全新文件，无版本列表、历史比较或再生成记录；应用内不持久化任何导出记录。VibeDrop 发布有按 `uniqueId` 复用的 slug 更新语义（见下节），但那是发布对象而非会话导出。

## 8. 分享载体、访问控制与撤销

- 会话导出的载体是本地文件：Web 与桌面端通过 anchor 下载，移动端写入系统目录，全程没有链接也没有远端对象。Web 端在备份完成后还可以调用系统 Share Sheet 交付备份 ZIP，这条路径只针对备份文件，见 `web_file_share.ts:6-22` 与 `general.tsx:646-669`。
- VibeDrop 发布：把聊天中可渲染代码块（HTML、XML、SVG、JS 等）的 HTML 内容发布成静态页。弹窗入口在 `src/renderer/modals/VibedropPublish.tsx`，发布逻辑在 `src/renderer/packages/vibedrop.ts`，代码块渲染与发布触发点见 `Markdown.tsx:583-595,646-660`。发布对象限于代码块，会话本身不进这条链路，主体归属生成式输出与运行时类目，本类目只记录边界。
- 认证与治理：发布前要登录 Chatbox 账号并签发按用户区分的发布 key（`issueVibedropKey`），key 缓存在设置项 `vibedropPublishKey` 中并绑定账号 email；可见性只有 `unlisted` 与 `public` 两档，同名 slug 可以更新，更新失败会提示 slug 已不再归属本账号；发布记录按会话保存最近 20 条。以上逻辑见 `vibedrop.ts:131-148,165-190`。管理入口在第三方站点 app.vibedrop.cc，删除、过期、克隆等治理由服务端承担，本地没有对应调用。
- 会话级公开链接分享（E4）：本次未找到（无分享 API 调用、无 URL 生成代码）。

## 9. 隐私、安全与内容治理

- 导出内容无过滤：system 提示词、工具 args/result（含可能的敏感数据）原样进入三种格式；reasoning 恰好被跳过。
- 备份侧有明确的密钥脱敏（`packages/chatbox-core/src/application/settings/export-projection.ts:19-74`）：不勾选 "API KEY & License" 时移除以下凭据，license 运行时状态无论勾选与否都剔除：
  - 提供商凭据与搜索密钥；
  - `MinerU token`；
  - `VibeDrop 发布密钥`；
  - `MCP env/headers`。
- HTML 转义缺口（源码直接确认）：以下字段均未转义直接拼入导出 HTML，消息正文经 React 默认转义，工具参数/附件名经 `escapeHtml`（lodash）。会话名或 URL 含特殊字符时可注入导出文件 DOM（自打开文件的 self-XSS 风险，需运行确认浏览器行为）。

| 未转义字段 | 拼入位置 | 定位 |
|---|---|---|
| `sessionName` | `<title>`、`<h1>` | `format-chat.tsx:112,125` |
| `thread.name` | `<h2>` | `:39` |
| 旧式图片 `p.url` | `src="..."` | `:86-88` |

- 外部资源：导出 HTML 依赖 Tailwind/KaTeX CDN 脚本与 chatboxai.app 图标域，打开文件时加载远端代码；受管图片内联 data URL 无跨域问题，远程图片 URL 保持原样引用。
- 备份导入有完整安全限制（路径穿越、重复 entry、大小与压缩比上限、manifest 校验，`types.ts:93-153` 与 `docs/technical/data-backup.md` 一致），导入后强制重启生效。

## 10. 性能、失败恢复与测试

- 生成全程在内存里拼接：Markdown 与 TXT 一次性构建成单个字符串，HTML 逐条消息异步读取 blob 后再拼接，没有大小上限、分页或分段写入，内容处理循环见 `src/renderer/lib/format-chat.tsx:35-106`。超长会话与超大图片的内存占用和耗时未验证。
- 会话导出的调用点没有局部错误处理或失败提示：弹窗以 void 调用 `exportSessionChat` 后立即关闭。若会话加载或 HTML 生成抛错，返回的 Promise 拒绝在这条调用链中没有 catch 处理（`src/renderer/modals/ExportChat.tsx:25-30`、`src/renderer/stores/session/export.ts:16-37`）。图片 blob 未读到内容且没有可用 URL 时，HTML 中的图片地址保留为空；读取本身抛错则继续沿异步调用链传播（`src/renderer/lib/format-chat.tsx:71-84`）。
- 平台交付：Web 端用 `<a download>` 加 ObjectURL 下载，1 秒后 revoke，见 `web_exporter.ts:14-40`。桌面平台复用 `WebExporter` 的下载实现，main 进程本次未找到 `will-download` 处理，Electron 默认的保存位置与是否弹框未运行验证，复用关系见 `desktop_platform.ts:33`。
- 移动端的 `MobileExporter` 与 `AndroidFilterWriter` 有完整的失败降级与取消收口：Documents 写入失败时改走 Cache 加系统选择器，日志分级输出，并有单测覆盖，见 `filter_writer.ts:656-811`。
- 测试：下列导出相关测试存在；对话导出的 Markdown/TXT 内容断言测试本次未找到。
  - `format-chat.test.tsx`（HTML 导出无交互按钮）
  - `backup-roundtrip.test.ts`（ZIP 往返）
  - `web_exporter.test.ts`、`filter_writer.test.ts`、`web_file_share.test.ts`、`VibedropPublish.test.tsx`
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
- `packages/chatbox-core/src/backup-export/session.ts`（Markdown/TXT 格式化、工具卡、附件名）
- `src/renderer/lib/format-chat.tsx`（HTML 静态渲染、图片内联、转义缺口）
- `src/renderer/components/Markdown.tsx`、`src/renderer/components/Mermaid.tsx`（导出端共享渲染、Shiki 同步/异步、Mermaid 异步、VibeDrop 入口）
- `src/renderer/platform/web_exporter.ts`、`src/renderer/platform/interfaces.ts`、`src/renderer/platform/desktop_platform.ts`、`src/renderer/platform/mobile_exporter.ts`、`src/renderer/platform/filter_writer.ts`（平台交付与降级）
- `src/renderer/routes/settings/general.tsx`（备份导出/导入/Share Sheet，与导出隔离）
- `src/renderer/packages/chatbox-core/src/backup-v3/`（types.ts 格式 v2、export-backup.ts、import-backup.ts、resources.ts、backup-roundtrip.test.ts）
- `src/renderer/packages/vibedrop.ts`、`src/renderer/modals/VibedropPublish.tsx`（代码块 HTML 发布边界）
- `src/shared/utils/message.ts`（`getMessageText` 默认排除 reasoning）
- `src/shared/types/session.ts`、`src/shared/types.ts`（contentParts/线程/导出类型 schema）
