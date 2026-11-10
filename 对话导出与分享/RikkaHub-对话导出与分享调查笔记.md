# RikkaHub 对话导出与分享调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`903e058b9361bff71d0b79f4ef2d8ac23d6597e6`（分支：`master`）
>
> 调查方式：静态源码调查（未运行应用、未执行单元测试）。通读 Android 端对话导出面板与位图生成、消息复制与"选择复制"、导出序列化器与 SAF/分享钩子、备份管理器与恢复暂存、Chatbox 与 Cherry Studio 导入器、WebDAV/S3 客户端及配置模型、Provider 二维码编解码，以及 web-ui 的 Markdown 导出工具与入口；未做真机渲染、系统分享面板、相册写入与远端备份往返回显验证。
>
> 调查范围：单条消息复制与"选择后整段导出"；Markdown 与 PNG 图片导出；配置类 JSON 与二维码的导入导出；全量备份与恢复（设置、数据库、文件）；Chatbox 与 Cherry Studio 外部备份导入；WebDAV/S3 备份；web-ui 端 Markdown 导出。不覆盖会话事实源与 Room schema 迁移细节、聊天现场消息渲染器、Artifact/工作区对象自身导出、系统级任意截图。
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

RikkaHub 没有单一的"分享对话"入口，导出能力分成三条彼此独立的链路：对话阅读导出、配置交换与全量备份。

对话阅读导出从聊天列表的多选态进入，确认后打开导出面板，只能产出 Markdown 文本或 PNG 长图，并把生成的文件交给 Android 系统分享面板（`ACTION_SEND`），不弹目录选择器另存（`ui/pages/chat/ChatList.kt`、`ui/pages/chat/ConversationExport.kt`）。面板提供“包含思考内容”总开关，Markdown 与图片都受它控制，图片另有一个“展开思考”开关。配置交换把 Provider 编码成 Base64 文本或二维码互导，提示词注入与世界书导出为 JSON 文件，其协议、字段与导入合并口径见 [LLM 渠道管理笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)。全量备份把设置、SQLite 数据库与文件目录打成 ZIP，可存本地或上传 WebDAV/S3，其包组成、暂存安装与路径校验见 [会话与消息管理笔记](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)。

三者的抽取口径差异明显。Markdown 把正文、reasoning（可关闭）、工具调用与图片内联进单个文件；图片导出用 Compose 离屏复刻一份 540dp 宽的位图，文档、视频、音频与工具内容不进入图片。完整会话树只存在于备份 ZIP 的数据库快照里——对话导出只取每个消息节点当前选中的那一条消息，Markdown 与图片都不导出备选分支。

备份是唯一可往返的能力，WebDAV/S3 只是把同一份 ZIP 上传到远端，不是增量同步；跨应用迁移通过 Chatbox Backup v2 与 Cherry Studio 备份导入实现，且方向单向。

## 系统边界与完整主链

```text
【A 对话阅读导出】
ChatList 多选 (selectedItems: MessageNode.id)
  -> ChatMessageActionsSheet「分享」= 选中从开头到该消息，或手动勾选任意消息
  -> 确认 -> ChatExportSheet (ui/pages/chat/ConversationExport.kt)
       ├─ Markdown: exportToMarkdown（includeReasoning 开关）
       │    -> appTempFolder/chat-export-<ts>.md -> FileProvider + ACTION_SEND(text/markdown)
       └─ Image: exportToImage（includeReasoning 与 expandReasoning 两个开关）
            -> BitmapComposer.composableToBitmap(ExportedChatImage, 540dp)（ui 模块）
            -> PNG 临时文件 + 相册 -> FileProvider + ACTION_SEND(image/png)

【B 配置交换导出】ShareSheet -> QRCode(zxing) 或 ACTION_SEND(text/plain)；ExportDialog -> CreateDocument("application/json") 或 ACTION_SEND（ui/hooks/ExportHooks.kt）
【C 全量备份】BackupPage -> BackupManager.createBackup -> 本地 ZIP / WebDAV / S3；恢复经 PendingRestore 暂存后重启生效
```

Android 端是三条链路的行为主体；web-ui 是 React 前端（构建产物由 Android 内嵌 web 服务托管），只通过输入区菜单导出 Markdown，不涉及图片、二维码与备份。

## 1. 入口、用户目标与导出源

| 能力 | 入口 | 导出源 | 目标 |
|---|---|---|---|
| 单条消息复制 | 消息操作栏 Copy 图标、操作面板 "Select and Copy" | 该消息所有 Text part | 剪贴板 |
| 任意消息范围导出 | 聊天列表多选 → 确认 → 导出面板 | 勾选的 `MessageNode.currentMessage` | 分享面板（md/png） |
| "从开头到本条"导出 | 消息操作面板「分享」 | 会话开头至该消息的全部节点 | 分享面板 |
| Provider 分享 | Provider 详情页分享按钮 | 当前 Provider（清空 models） | 文本分享 + 二维码 |
| Lorebook/注入 JSON | 扩展页导出按钮 | 单个实体 | 文件或 JSON 分享 |
| 全量备份 | 侧边栏 → 备份页 | 设置 + 数据库 + 文件 | 文件 / WebDAV / S3 |

对话导出的唯一入口是聊天列表的多选态。消息操作面板的「分享」把 `selecting` 置真，并选中从会话开头到该条消息的全部节点，因此它承担“截取到此处”的整段导出（`ui/pages/chat/ChatList.kt`）；确认按钮汇总被选节点后打开导出面板（`ConversationExport.kt`）。

备份页由侧边栏进入，路由为 `Screen.Backup`（`ChatDrawer.kt`），分本地导入导出、WebDAV、S3、备份提醒四个标签页（`backup/BackupPage.kt`）。

## 2. 范围选择、内容口径与字段过滤

对话导出按下标顺序遍历选中的消息节点，每条只取当前选中的那一条消息，不含该节点的其它备选分支（`ChatList.kt`）。因此导出粒度是“消息序列”而不是“分支树”，没有 range、时间过滤或按角色过滤开关。

Markdown 口径（`ui/pages/chat/ConversationExport.kt` 的 `exportToMarkdown`）：

| 内容 | 处理 |
|---|---|
| 会话标题 | `# ${conversation.title}`，无转义 |
| 导出时间 | `*Exported on <本地时间>*` |
| 角色 | 仅区分 `**User**` 与 `**Assistant**`，其余一律记为 Assistant |
| Text | 原样追加 |
| Image | `![Image](data:image/...;base64,...)` 内联 data URL |
| Reasoning | 非空行前缀 `> `，`ExportOptions.includeReasoning` 默认开启、可在面板关闭；多行思考逐行加前缀 |
| Tool | 工具名 + Call ID + `json` 输入块 + 输出；输出图片内联 base64，文档/视频/音频保留 URL 链接 |
| 其它 part | 跳过 |

图片导出口径更窄（`ConversationExport.kt` 的 `exportToImage`）：只渲染 Text、Image 与思考块中的 reasoning/工具步骤标题，文档、视频、音频等 part 不渲染（源码注释“Other parts are not rendered in image export for now”）。思考内容默认折叠，`expandReasoning` 开关在 `includeReasoning` 关闭时置灰；空消息（`isEmptyUIMessage`）直接跳过。

web-ui 的 Markdown 口径独立实现（`web-ui/app/lib/export-markdown.ts`）：只处理 text、reasoning（需显式开关）、image 与 document（均保留原 URL、不内联），工具内容本次未找到处理，且同样只导出每条节点选中的分支。

配置类导出保留完整实体字段，世界书与注入导入时重新生成 id；Provider 分享会清空 `models`，其二维码/文本协议、前缀校验与导入合并去重口径见 [LLM 渠道管理笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)。

## 3. 附件、资源与离线封装

四类交付物的资源策略不同。Markdown 把图片转成 Base64 data URL 内联，单文件可离线打开但含图对话体积增大；文档、视频、音频只留外部 URL，离线时链接不可用，工具输出图片同样内联。图片长图是位图快照，图片以像素替代、离线可看，但文档/视频/音频不出现，工具步骤只留标题行；渲染用 `AsyncImage` 且 `allowHardware(false)`，最大高度 300dp（`ConversationExport.kt`）。备份 ZIP 是唯一资源级封装，其目录清单与恢复白名单见 [会话与消息管理笔记](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)。二维码与配置 JSON 不携带二进制资源。

## 4. 格式、schema 与往返能力

对话导出只有 Markdown 与 PNG 两种格式（`ConversationExport.kt` 的导出面板），两者都没有 schema、消息 ID、时间戳、模型或分支元数据，无法据其恢复会话，属于一次性阅读交付；JSON/HTML/PDF 形式的对话导出本次未找到。Markdown 与图片都不能反向导入。

配置类导出统一装进版本号为 1 的信封，字段是 version、type 与 data，其中 type 只有 `mode_injection` 与 `lorebook` 两种取值。序列化时忽略未知字段、写出默认值，输出非美化 JSON（`data/export/ExportSerializer.kt`）。导入按类型分叉：世界书先解析原生信封，失败后降级尝试 SillyTavern 的世界书结构；注入只接受原生信封。

可往返的是备份 ZIP：它没有 manifest 或版本号，靠固定文件名约定，设置读取时先经 `SettingsJsonMigrator.migrate` 做旧版兼容（`BackupManager.kt`），ZIP 结构本身没有版本协商；包构成与 Chatbox/Cherry Studio 导入校验见 [会话与消息管理笔记](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)与 [LLM 渠道管理笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)。

## 5. 分享稿编辑、编排与预览

不适用。RikkaHub 没有独立的分享稿编辑或预览工作台，三条链路都是直接生成，没有中间的编辑环节。

对话导出面板没有预览、内容开关或排序能力，除图片导出的"展开思考"外没有任何布局、主题、水印自定义；点击后立即生成并拉起分享面板。配置导出同样没有编辑面。备份页只提供备份项多选（数据库/文件），没有内容级编辑。

## 6. 图片、HTML、PDF 与富内容生成

图片（E3）由 Compose 组件重新排版后绘制成整张位图，当前视口与 WebView/Canvas 都不参与出图。做法是在目标 Activity 的 decorView 上临时挂一个不可见的 Compose 容器，按给定宽度与屏幕密度测量布局，用固定 100ms 延迟等异步内容加载，再遍历绘制成位图并移除容器；尺寸上限为 10000dp×10000dp，未给高度时按内容自撑。入口见 `BitmapComposer.composableToBitmap`（`ui` 模块）。

导出的画面由 `ExportedChatImage` 组合出来：套用 `RikkahubTheme` 主题，宽度固定 540dp，顶部依次是会话标题、本地时间、rikka-ai.com 与应用图标，中间逐条列出消息，底部固定一行半透明的 10sp 水印（文案取 export_image_warning）。助手消息紧跟前一条用户消息时，额外显示模型图标与模型名。布局定义见 `ConversationExport.kt`。

点击图片导出后按顺序做三件事：把位图压缩成 PNG 写入临时文件，保存一份到相册，再通过 FileProvider 以 `image/png` 交给系统分享面板。相册写入按系统版本分叉：Android 10 及以上通过 MediaStore 存进 Pictures 目录，更低版本直接写外部存储并广播媒体扫描，需要 `WRITE_EXTERNAL_STORAGE` 权限。三步流程见 `ConversationExport.kt` 的 `exportToImage`，版本分叉的相册写入见 `utils/ContextUtil.kt`。

Markdown 导出是纯字符串拼接（`buildAnnotatedString` 后取字符串），没有图片渲染与分页；HTML 与 PDF 导出本次未找到。配置二维码由 zxing 生成 512×512 位图（`ui/components/ui/QRCode.kt`），其编码协议见 [LLM 渠道管理笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)。图片生成资产本身的展示与删除属于 [媒体创作笔记](../媒体创作/RikkaHub-媒体创作调查笔记.md)。

## 7. 生成历史、版本与持久化

不适用。所有导出都是一次性产物：每次生成新文件名（`chat-export-<yyyy-MM-dd_HH-mm-ss>`、`rikkahub_backup_<yyyyMMdd_HHmmss>`），不覆盖、不追加、无版本列表或历史比较。临时文件写入 `appTempFolder`/cache 后交给分享面板或 SAF，应用内不保留导出记录。

备份侧只持久化一个"上次备份时间"用于提醒（`BackupVM.kt`），没有备份历史或版本管理；WebDAV/S3 端也只保留远端文件列表，不是版本对象。

## 8. 分享载体、访问控制与撤销

本地分享载体是 Android 系统分享面板。三条链路都用 `Intent.createChooser` 包一个 `ACTION_SEND` 选择器，并授予 `FLAG_GRANT_READ_URI_PERMISSION` 让接收方临时读取，文件统一由 `${packageName}.fileprovider` 暴露。各交付物的 MIME 类型与分享入口如下：

| 交付物 | MIME 类型 | 分享入口 |
| --- | --- | --- |
| Markdown | `text/markdown` | `ConversationExport.kt` 的 `shareFile` |
| 图片 | `image/png` | 同上 |
| 配置 JSON | `application/json` | `ui/hooks/ExportHooks.kt` |
| Provider 文本 | `text/plain` | 同上 |

本地备份导出走另一条路：用 SAF 的 CreateDocument 请求 application/zip，由用户选定保存位置（`backup/tabs/ImportExportTab.kt,227-252`），不经过分享面板。

远端传输面是 WebDAV 与 S3，两者都只把备份 ZIP 送进用户自己的远端存储，并能列出、下载恢复与删除。它们不提供长期分享链接、公开页、token 或过期语义，访问控制完全由用户配置的服务器凭据决定。

- WebDAV：上传到配置项 `path` 指定的目录（默认 rikkahub_backups），列目录时只认 `backup_` 前缀、以 `.zip` 结尾的文件，按修改时间倒序（`data/sync/webdav/WebDavSync.kt`）。
- S3：使用固定前缀 rikkahub_backups/backup_*.zip，能力与 WebDAV 一致（`data/sync/S3Sync.kt`）。

二维码分享是明文凭据传播，其前缀校验、无签名/有效期与导入去重口径见 [LLM 渠道管理笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)。

## 9. 隐私、安全与内容治理

对话导出没有任何脱敏或敏感内容开关。system 消息（会话级自定义系统提示）在 Markdown 里按角色标记输出（非 User 即记 Assistant），reasoning 与工具调用含可能的路径、查询与结果，全部原样进入交付物；图片导出则把思考折叠并隐藏工具内容。三条链路都没有导出前的密钥检查引导。

配置与备份侧把凭据明文写进交付物，有两个出口：

- Provider 的二维码与文本分享：带 `apiKey`，并把 `models` 清空（`ShareSheet.kt`）。
- 备份 ZIP：其中的 settings.json 是完整的设置序列化，provider 的 `apiKey`、自定义 header 都在里面；本次未找到导出时的脱敏或过滤开关（`BackupManager.kt`）。

投递安全方面，Markdown 把会话标题、消息正文与图片 URL 直接拼接，未做转义；图片文件名固定无非法字符问题，但 web-ui 用原始标题作 `${detail.title}.md`，非法字符行为取决于浏览器。

恢复与导入路径的防护（条目路径校验、目录穿越、完整性检查与重试）属于备份与导入实现，见 [会话与消息管理笔记](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)。

## 10. 性能、失败恢复与测试

图片导出在内存中构建整张位图，上限 10000dp×10000dp，无分页或分段；超长会话与超大图的内存、耗时未运行验证。它等待异步内容只靠固定 `postDelayed(100ms)`（`ui` 模块的 `BitmapComposer`），远程图片是否来得及加载属运行时行为；Markdown 导出是线性拼接，无大小上限。

对话导出的失败反馈较弱。图片导出点下按钮后先启动协程生成，紧接着就弹出成功提示，真正失败时再补一条错误提示，用户会先看到成功；Markdown 导出把异常在内部捕获后只打印堆栈，不给用户失败提示。两条链路都没有取消机制，实现见 `ConversationExport.kt` 的 `exportToImage` 与 `exportToMarkdown`。

测试覆盖方面，备份暂存与回滚、外部备份导入、Provider 编解码往返各有测试（分别见 [会话与消息管理笔记](../会话与消息管理/RikkaHub-会话与消息管理调查笔记.md)、[LLM 渠道管理笔记](../LLM渠道管理/RikkaHub-LLM渠道管理调查笔记.md)）；对话导出本身本次未找到对应测试。

## 11. 设计取舍与已确认边界

- 三套"导出"互不复用：对话阅读导出（md/png，即生成即分享）、配置交换（JSON/二维码）、全量备份（ZIP，迁移恢复），格式与口径都不同；对话导出只处理当前选中分支、不导附件下载，定位是人际传播而非归档，完整会话树只能从备份 ZIP 的数据库快照获得。
- 图片导出选择"离屏复刻 Compose 组件"而非系统截图，可复用应用主题与消息组件，但受组件异步渲染影响（固定延迟等待），且富内容（文档/视频/音频、工具内容）不在图片中渲染。
- 备份是唯一可往返能力，需要重启；WebDAV/S3 只是备份 ZIP 的远端存放位，不是实时增量同步，也不提供公开分享语义。
- 外部迁移方向是单向的：RikkaHub 能读 Chatbox Backup v2 与 Cherry Studio 备份（后者仅 provider），但没有面向其他应用的通用导出。

## 12. 未验证事项

- 图片导出在真机上的实际保真度（代码高亮、LaTeX/表格、工具步骤与折叠呈现），以及远程图片能否在 100ms 内加载完成；不成立时长图可能缺图。
- 相册写入（MediaStore/旧版权限链）与分享面板在各 Android 版本与厂商 ROM 上的实际行为。
- Markdown 内联的 Base64 图片在接收方应用中是否被渲染，以及含图长会话的文件体积与传输表现；消息内表格、图表与 Mermaid 是否随 Markdown 导出未在已读口径内逐项确认。
- WebDAV/S3 与具体服务端实现的兼容性（自建 WebDAV 的 PROPFIND 细节、S3 兼容端点的签名与 path-style 行为）；本次只读客户端代码。
- 备份 ZIP 跨版本升级时的实际兼容范围，以及数据库迁移失败时的用户可见行为。
- web-ui `${title}.md` 的非法字符清洗由浏览器决定，实际下载文件名未验证。
- 本次未找到对话的 JSON/HTML/PDF 导出，以及备份中的凭据脱敏开关；结论限本快照已读入口。

## 13. 关键源码索引

- `app/src/main/java/me/rerere/rikkahub/ui/pages/chat/ConversationExport.kt`（对话导出面板、Markdown 拼接、图片离屏复刻、分享）
- `app/src/main/java/me/rerere/rikkahub/ui/pages/chat/ChatList.kt`（多选、分享入口、“截取到此处”）
- `ui/src/main/java/me/rerere/ui/components/BitmapComposer.kt`、`app/src/main/java/me/rerere/rikkahub/ui/components/message/ChatMessageActions.kt`、`ChatMessageCopySheet.kt`（Composable → Bitmap、复制与选择复制）
- `ai/src/main/java/me/rerere/ai/ui/Message.kt`（`toText` 仅拼接 Text part）
- `app/src/main/java/me/rerere/rikkahub/ui/components/ui/ShareSheet.kt`、`QRCode.kt`、`ui/components/ui/Export.kt`（Provider 文本/二维码编解码、配置导出对话框）
- `app/src/main/java/me/rerere/rikkahub/data/export/ExportSerializer.kt`、`ui/hooks/ExportHooks.kt`（配置类 JSON 信封、SAF/分享钩子）
- `app/src/main/java/me/rerere/rikkahub/data/sync/webdav/WebDavSync.kt`、`data/sync/S3Sync.kt`、`ui/pages/backup/BackupPage.kt`、`tabs/ImportExportTab.kt`（远端传输、备份页与本地导入导出）
- `app/src/main/java/me/rerere/rikkahub/utils/ContextUtil.kt`、`utils/ChatUtil.kt`（相册写入、剪贴板）
- `web-ui/app/lib/export-markdown.ts`、`app/routes/conversations.tsx`（Web 端 Markdown 导出）
