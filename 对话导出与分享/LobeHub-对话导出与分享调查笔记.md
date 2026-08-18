# LobeHub 对话导出与分享调查笔记

> 调查对象：`https://github.com/lobehub/lobehub`
>
> 调查更新日期：2026-08-14
>
> 代码快照：`3b57a07e3cc1f6b5aaabad36112e8ba40142df29`（分支：`canary`）
>
> 调查方式：静态源码调查；读取前端 ShareModal/SharePopover/ShareMessageModal、store/service 调用链、服务端 lambda 路由器（topic、share、message、exporter）、数据库模型与 schema（TopicModel/TopicShareModel/TopicImporterRepo）、类型定义（ExportedTopic/ImportedMessage/SharedTopicData）及路由注册；未运行应用、未访问远端分享页
>
> 调查范围：Topic 的复制/导入/转发（站内操作 vs 对外交付的边界）、四格式导出（截图/文本/PDF/JSON）、链接分享（SharePopover、/share/t/:id 公开页、访问语义与撤销）、附件与跨域资源处理、导入往返；不覆盖整库备份恢复（exporter.exportData 仅作边界说明）、Agent 实体导出、文档对象分享（/share/page 路由）、社区市场发布
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

LobeHub 把"复制/导入 Topic"与"导出/分享"明确分成两个面：前者是站内管理操作（`cloneTopic`、`importTopic`、`forwardTopic`），在数据库内部完成，不产生任何交付文件；后者是面向交付的四格式导出弹窗（截图/文本/PDF/JSON）与一个独立的链接分享体系（`topic_shares` 表 + `/share/t/:id` 公开页）。

本地导出通过 `ShareModal` 统一入口提供四个 Tab：
- 截图：`@zumer/snapdom` 对专用分享版式离屏成像，支持 JPG/PNG/SVG/WEBP，DPR=2；
- 文本：Markdown 预览 + 复制/下载；
- PDF：服务端 `marked`+`pdfkit` 渲染，运行时从 CDN 下载中文字体；
- JSON：simple（OpenAI 风格）与 full（无损 `ExportedTopic` v2.0）两种模式。

另有一个单消息分享弹窗（截图/文本/PDF，仅助手消息）。四处导出均无选区与版本历史，JSON full 与 `importTopic` 构成可往返的导入链路。

链接分享是实时分享而非快照：分享页每次请求都从 `topic_shares` 关联的源 topic 现读消息；`visibility` 为 `'link'` 时匿名可访问，`'private'` 时仅创建者可见；分享记录可被 `disableSharing` 删除（本次未找到客户端 UI 调用）。

OSS 仓库默认 `ENABLE_BUSINESS_FEATURES = false`，聊天头部的 SharePopover（链接分享入口）被该开关隐藏，导出弹窗不受影响。

## 系统边界与完整主链

三类主链：

```text
站内复制/导入（无交付物）：
  Topic 菜单 duplicate -> topicService.cloneTopic -> topic.cloneTopic
  -> TopicModel.duplicate（新 topic + 消息 + messagePlugins，metadata.copied）
  Topic 菜单 import(.json 上传) -> importTopic action -> topic.importTopic
  -> TopicImporterRepo.importTopic（JSON 解析 -> 新 topic + 消息 + 插件）

本地导出（交付文件）：
  当前会话/Topic 菜单 share -> ShareModal
    -> ShareDataProvider（按 conversation context 拉 dbMessages/displayMessages）
    -> 截图 Tab：ShareImage.Preview 专用版式 -> snapdom -> 复制/下载
    -> 文本 Tab：generateMarkdown -> 复制 / 下载 <title>.md
    -> PDF Tab：generateMarkdown -> exporter.exportPdf（服务端 pdfkit）-> base64 -> 下载
    -> JSON Tab：generateMessages / generateFullExport -> 复制 / 下载 <title>.json

链接分享（远端公开页）：
  SharePopover（enableBusinessFeatures 开关）-> topic.enableSharing（建 share 记录）
    -> 复制 <origin>/share/t/<shareId>
  -> 访客打开 /share/t/:id -> share.getSharedTopic（publicProcedure，校验 visibility）
    -> message.getMessages(topicShareId)（以 share 属主身份实时读源 topic 消息）
    -> 分享页 ChatList 渲染 + 附件经 /f/:id 公开文件代理
```

## 1. 入口、用户目标与导出源

| 入口 | 位置 | 目标 |
|---|---|---|
| Topic 右键菜单 duplicate | `src/features/AgentSidebar/Topic/List/Item/useDropdownMenu.tsx:238-247` | 站内复制，立即切换到新 topic |
| Topic 列表菜单 import（`.json` 上传） | `src/features/AgentSidebar/Topic/useDropdownMenu.tsx:103-120` | 将导出文件重建为当前 agent 下的新 topic |
| 会话头部 Share 按钮 | `src/routes/(main)/agent/features/Conversation/Header/ShareButton/index.tsx:23-57` | 打开导出弹窗；business 开关开启时变为 SharePopover（链接分享+导出） |
| Topic 右键菜单 share | `useDropdownMenu.tsx:270-277`（`handleOpenShareModal` 90-94） | 直接打开导出弹窗 |
| 消息悬浮操作条 share | `src/features/Conversation/Messages/components/MessageActionBar/actions/share.tsx:9-32`（`ctx.role === 'user'` 时返回 null，仅助手消息） | 单消息分享弹窗（截图/文本/PDF） |
| 群会话头部、AgentTask 抽屉 | `src/routes/(main)/group/features/Conversation/Header/ShareButton/index.tsx`、`src/features/AgentTasks/AgentTaskDetail/TopicChatDrawer/index.tsx:201-217` | 同上，均按 `enableTopicLinkShare` 决定是否挂 SharePopover |

导出源是"当前 conversation context 的整个 topic 消息集"，无单条勾选或连续范围选择；ShareDataProvider 在无 topicId 时跳过拉取（`src/features/ShareModal/ShareDataProvider.tsx:68`），即导出必须依附于一个已存在的 topic。文本/PDF 使用 `displayMessages`（聊天现场展示口径，含线程处理，`src/store/chat/slices/message/selectors/displayMessage.ts:40-44`）；JSON 使用 `dbMessages`（数据库原始口径）。

## 2. 范围选择、内容口径与字段过滤

- **范围**：固定为当前 topic 全部消息，顺序按服务端返回顺序；无选区、无"从开头到某条"、无分支选择。线程消息：分享弹窗以 `threadId: null` 打开（`useDropdownMenu.tsx:93`），只导出主链；单消息分享则只取该条消息（`ShareMessageModal/ShareText/index.tsx:25`）。
- **内容口径**：三条路径口径不同：
  - 截图与分享页走聊天现场同一套 `MessageItem` 渲染（`src/features/ShareModal/ShareImage/ChatList/index.tsx:23-25`、`src/routes/share/t/[id]/SharedMessageList.tsx:37-40`），所见即所得；
  - 文本/PDF 从 `displayMessages` 的 `content` 字段拼接（`ShareText/template.ts:13-61`）；
  - JSON full 从 `dbMessages` 逐字段投影。
- **system/reasoning/工具**：文本导出对三类内容处理不同：
  - 角色与工具：默认 `withRole` 输出 User/Assistant/Tools Calling 三级标题，工具消息内容包进 JSON 代码块（`template.ts:40-58`）；`includeTool`/`includeUser` 可关闭；
  - system prompt：由 `withSystemRole` 开关控制（多入口默认 false，JSON 默认 true）；
  - reasoning 与 artifact：文本导出不剥离思考内容，预处理保留 `<think>`/`<lobeThinking>` 与 artifact 标记结构；预处理函数见 `normalizeThinkTags`、`processWithArtifact`（`template.ts:34`、`src/features/Conversation/utils/markdown.ts:19-96`）；
  - 占位消息：`LOADING_FLAT` 被过滤（`template.ts:29`）。
- **隐藏分支**：本次未找到导出隐藏分支或全部版本内容的路径；`generateFullExport` 按消息数组原样输出（`ShareJSON/generateFullExport.ts:23-52`），不区分活动路径与旁支。

## 3. 附件、资源与离线封装

- **JSON full**：
  - 输出字段：`content`、`plugin`、`pluginState`、`tools`、`reasoning`、`metadata`（`generateFullExport.ts:26-51`）；
  - 不含：消息模型查询时拼接的 `files` 附件数组——附件不打包进任何导出文件。
- **Markdown/PDF**：消息 content 中的图片 Markdown 链接（通常为 `/f/:id` 访问 URL）按原文保留；无内联、无代理转换，离线打开时引用可能失效。PDF 服务端渲染根本不解析图片/表格 token（见 §6）。
- **截图**：三条行为：
  - `snapdom`（`@zumer/snapdom` ^1.9.14，package.json 顶层依赖）对 DOM 成像时会内联资源；
  - 栅格格式经 `useProxy: 'https://proxy.corsfix.com/?'` 跨域图片代理（`src/hooks/useScreenshot.ts:54-57`）；
  - 分享版式头部渲染模型/插件标签（`ShareImage/Preview.tsx:115-120`），`withPluginInfo` 默认关闭。
- **分享页附件**：
  - 服务端返回消息时把文件 URL 改写为访问 URL（`apps/server/src/routers/lambda/message.ts:393-395`）；
  - 生产环境为 `/f/:id` 公开代理（`apps/server/src/services/file/index.ts:128-136`）。该端点注释明确 intentionally unauthenticated（`src/app/(backend)/f/[id]/route.ts:20-23`）：按 id 公开访问、302 到预签名 URL；
  - `/f/:id` 路由属于 web 壳，Electron 桌面端未注册分享路由（`src/spa/router/desktopRouter.sync.test.tsx:199-207`）。

## 4. 格式、schema 与往返能力

- **Markdown**：`<title>.md`，`# 标题` + 角色三级标题 + 正文（`ShareText/template.ts:22-61`），无版本号；导出端可再导入的只有 JSON。
- **JSON**：两种模式（`packages/types/src/export.ts:20` `TopicExportMode`）：
  - simple：`{role, content}` 数组，可选前置 system 消息，带 `tool_call_id`/`tools`（`ShareJSON/generateMessages.ts:11-36`）；
  - full：`ExportedTopic`，`version: '2.0'`、`title`、`exportedAt`、messages 数组（`generateFullExport.ts:66-71`；`packages/types/src/export.ts:26-35`）。
- **往返**：full/simple 文件均可经 "Topic 列表 -> 导入 .json" 回到 `topic.importTopic`（`apps/server/src/routers/lambda/topic.ts:641-662`）。`TopicImporterRepo`（`packages/database/src/repositories/topicImporter/index.ts:125-141`）的处理行为：
  - 按 `version` 键是否存在区分两种格式，但不校验版本值；
  - 过滤 system 消息、重建 `parentId` 链、重生成消息 ID，并把插件写入 `messagePlugins`（`index.ts:77-118,146-241`）；
  - 无 parentId 的简单数组按数组顺序补成线性链（`index.ts:234-238`）；
  - 不导入：文件关联（`messagesFiles`）、翻译、TTS、压缩组。往返语义成立但非无损。
- **导出不携带分享稿编辑痕迹**：schema 中无分享稿对象，导出即当前数据的一次投影。

## 5. 分享稿编辑、编排与预览

- 截图 Tab：独立分享版式（品牌头像、标题、模型标签、可选 system role 区、消息列表、可选页脚品牌区，`ShareImage/Preview.tsx:89-140`）；实时预览与生成物是同一 DOM（`id="preview"`），无独立"渲染-生成"两条管线。可配置项共六个：
  - `widthMode`：窄 480px 或宽 100%（`src/features/ShareModal/useContainerStyles.ts:36-43`）；
  - `withBackground`：装饰背景（`ShareImage/style.ts:6-13`）；
  - `withFooter`：页脚品牌区开关；
  - `withSystemRole`：system role 区开关；
  - `withPluginInfo`：头部模型/插件标签开关；
  - `imageType`：输出图片格式。
- 文本/JSON Tab：侧栏选项 + 预览区（`Markdown` 渲染 / JSON 缩进文本），复制与下载用同一份 `content` 字符串（`ShareText/index.tsx:64-98`、`ShareJSON/index.tsx:87-115`）。
- 移动端布局：选项表单折叠到底部按钮区（各 `index.tsx` 的 `isMobile` 分支）。
- 本次未找到：自定义字体、分页、水印、品牌覆盖、元信息编辑或分享稿工作台。

## 6. 图片、HTML、PDF 与富内容生成

- **截图**：三条行为与一个边界：
  - 成像：`useScreenshot` 用 `snapdom`（html-to-image 系 fork）对 `#preview` DOM 成像，DPR 固定为 2（`scale: 2`）。SVG 走 `toRaw`，栅格走 `toBlob`（`src/hooks/useScreenshot.ts:39-64`）；
  - 复制为 PNG：`toBlob` → `ClipboardItem` → `navigator.clipboard.write`（`src/hooks/useImgToClipboard.ts:13-24`）；
  - 下载为 data URL（`<a download>`），文件名按 `${BRANDING_NAME}_${title}_${date}.${ext}` 模板生成（`useScreenshot.ts:102-115`）；
  - 无长图分段拼接、无 Canvas 尺寸上限处理代码。
- **PDF**：`exporter.exportPdf` 在服务端生成（`apps/server/src/routers/lambda/exporter.ts:182-198`）：
  - 渲染：`marked` lexer 分词后由 `pdfkit` 逐 token 排版（heading/paragraph/list/blockquote/code/hr，`exporter.ts:89-149`），A4、50px 边距、页码；
  - 字体：中文字体运行时从 jsdelivr CDN 拉取 Source Han Sans（`exporter.ts:30-47`），失败即抛错；
  - 保真度：不处理图片、表格、数学、Mermaid 与行内代码高亮（token 文本化输出）；
  - 访问控制：OSS 下 RBAC 中间件是放行桩（`packages/business-server/src/trpc-middlewares/rbacPermission.ts:14-28`），登录用户即可用。
- **富内容保真**：截图与分享页直接复用聊天现场 `MessageItem`/`ChatList` 渲染器（含 Markdown、工具卡、Artifact、图片等全部现场表达）；文本导出则回到纯 Markdown 文本，工具调用以 `tools` JSON 代码块形式出现（`ShareText/template.ts:55-58`）；PDF 保真度最低（纯文本流）。

## 7. 生成历史、版本与持久化

- 截图/文本/JSON：每次点击复制/下载即时生成，无历史列表；选项变化重渲染即得新结果。
- PDF：`usePdfGeneration` 有"生成/重新生成"按钮，但 `pdfData` 只存在组件状态，重新生成覆盖（`SharePdf/usePdfGeneration.ts:20-53`），关闭弹窗即丢失，无版本对比或持久化。
- 分享链接：`topic_shares` 一条记录对应一个 topic（`topicId` 唯一索引），没有同一分享的多版本；分享页展示的是源 topic 实时数据（见 §8），"更新"即源 topic 本身的变化。

## 8. 分享载体、访问控制与撤销

- **载体**：`topic_shares` 表（`packages/database/src/schemas/topic.ts:231-258`）承载分享记录：
  - `shareId`：8 位 nanoId（`:235`）；
  - `visibility`：默认 `'private'`；
  - `pageViewCount`：访问计数；
  - topic 删除时分享记录级联删除（`:240`）。
- **创建/更新**：服务端三个操作（`apps/server/src/routers/lambda/topic.ts:412-458,871-894`；模型实现 `packages/database/src/models/topicShare.ts:43-116`）：
  - `enableSharing`：建记录（`onConflictDoNothing` 幂等）；
  - `updateShareVisibility`：切换 private/link；
  - `disableSharing`：删记录。
  SharePopover 打开时若尚无记录会**自动创建 private 分享**（`src/features/SharePopover/index.tsx:80-84`）；切到 link 时自动复制链接并 toast（`index.tsx:97-103`），并弹出隐私提醒（工具调用、凭据、图片、文件四类，`index.tsx:113-160`）。
- **访问语义**：
  - 判定：`findByShareIdWithAccessCheck`（`topicShare.ts:214-235`）——private 仅 owner（`accessUserId === ownerId`）可读，link 任何人可读；
  - 公开入口：`publicProcedure`（`packages/trpc/src/lambda/index.ts:34`，匿名免登录），`share.getSharedTopic` 返回元数据并自增 `pageViewCount`（`apps/server/src/routers/lambda/share.ts:14-56`）；
  - 实时读取：`message.getMessages` 带 `topicShareId` 时以分享属主身份现读消息（`apps/server/src/routers/lambda/message.ts:347-411`），并强制 `skipWorks: true` 防止把运行中的 Work 状态泄漏给访客（`message.ts:387-391` 注释）。
- **快照 vs 实时**：实时。分享页每次请求都读源 topic 当前消息；分享记录本身（标题、agent 元数据）在创建时固化于 join 查询，消息内容不固化。
- **撤销/删除**：
  - `disableSharing` 删记录后 shareId 不可解析（NOT_FOUND）；但本次未找到客户端 UI 调用它——SharePopover 只有 private/link 选择器，切回 private 即对非 owner 隐藏，记录保留；
  - workspace 模式下分享管理限创建者或 workspace owner（`assertCanManageTopicShare`，`topic.ts:98-117`），并有 `resource.shared/unshared` 审计日志（`topic.ts:125-142`）。
- **入口开关**：配置下发链路为：OSS 常量 `ENABLE_BUSINESS_FEATURES = false`（`packages/business/const/src/index.ts:7`）→ 服务端 `getServerAuthConfig` 下发（`apps/server/src/globalConfig/getServerAuthConfig.ts:16`）→ SharePopover 仅在 `serverConfig.enableBusinessFeatures` 为真时挂载（`ShareButton/index.tsx:27,50-54`）。即：链接分享的服务端与页面代码都在本仓库，但 OSS 自托管默认从 UI 隐藏入口；云版覆盖该开关。
- **分享页**：会话分享页 `/share/t/:id`（Web/移动端注册，Electron 不注册）：
  - 复用 `ShareShell`，正文用 `SharedMessageList` 以 `topicShareId` 上下文拉消息（`src/routes/share/t/[id]/index.tsx:14-44`、`SharedMessageList.tsx:19-65`）；
  - 禁用编辑与操作条，页脚显示免责声明（`sharePageDisclaimer`）。
  `/share/page/:id` 是文档对象分享，不在本类目范围。

## 9. 隐私、安全与内容治理

- 分享前有隐私提醒（private->link 时，含"不再提醒"选项并持久化到 systemStatus，`SharePopover/index.tsx:113-160,41-46`）；导出弹窗本身无敏感内容扫描或过滤。
- reasoning/think 内容在文本导出中保留（`normalizeThinkTags` 只重排换行不剥离）；system role 由 `withSystemRole` 开关控制（默认 off，JSON 默认 on）。
- 文件 URL 在分享页经 `getFileAccessUrl` 改写为 `/f/:id`；该代理无鉴权、按 id 公开（`src/app/(backend)/f/[id]/route.ts`），即"知道 id 就能访问"是既有设计而非分享页私有通道；服务端消息 join 对失去访问权的文件返回 `url: ''` 防泄漏（`packages/database/src/models/message.ts:1097-1105` 一带）。
- PDF 由服务端从 Markdown 纯文本渲染，无脚本执行面；截图/分享页是客户端自渲染 DOM，不引入外部 HTML。
- 本次未找到导出中的水印、密钥/个人信息扫描、文件名净化逻辑。

## 10. 性能、失败恢复与测试

- 失败反馈：三条路径各不相同：
  - 截图复制/下载失败仅 `console.error`（`useScreenshot.ts:111-114`、`useImgToClipboard.ts:21-24`）；
  - PDF 生成失败显示错误块与"错误描述"（`SharePdf/index.tsx:146-170`）并可重试；
  - importTopic 失败弹 `importError` toast 并复位（`src/store/chat/slices/topic/action.ts:277-282`）。
- 长会话：截图无分段拼接；PDF 逐 token 换页但无页数上限控制代码；分享页分页参数存在（`limit/offset`，`topic.ts:153-183` `getTopicTranscript`）。
- 测试：`apps/server/src/routers/lambda/__tests__/integration/topicShare.integration.test.ts`（enable/update/disable 的属主与越权矩阵）、`topic.integration.test.ts` 的 cloneTopic 用例、`topic.test.ts` 的 share 各方法 mock 用例；PDF/截图生成未见自动化测试。运行验证（图片保真、字体 CDN、跨域代理、剪贴板、匿名访问）本次均未执行。

## 11. 设计取舍与已确认边界

- **站内操作与对外交付分离**：`cloneTopic`（复制）、`importTopic`（导入）、`forwardTopic`（把整 topic 转录作为用户消息发给另一 agent，`src/store/chat/slices/forward/action.ts:99-106`）都是数据库内操作，无文件产出；"转发"连复制都不算，只生成一段转录文本作为新对话首条消息。
- **复制语义**（`packages/database/src/models/topic.ts:1086-1198`）：
  - 继承：新 topic 原位继承 `agentId`/`groupId`/`sessionId`；
  - 重置：usage 汇总清零（`COPIED_TOPIC_USAGE_RESET`，`copiedTranscript.ts:55-62`）；
  - 消息重写：生成新 id、按映射重建 `parentId` 链、tools 的 id 与 plugin `toolCallId` 换新、`metadata.copied: true` 标记（`copyMessagesInDatabase.ts:32-38`）；
  - 计数口径：token/cost 数字保留，但用量报表过滤 copied 行（`copiedTranscript.ts:36-44`）；
  - 不复制：`messagesFiles`（文件关联）、translates、TTS、messageGroups（压缩组）、chunks/queries；与 SQL 版 `copyMessagesInDatabase`（覆盖全部子表，`:253-304`）口径不同，topic 复制是较轻的一份。
- **导出四格式共用同一数据源与预览-产物一致原则**：截图预览即产物；文本与 PDF 共享 `generateMarkdown` 的同一份 content 字符串，JSON 的预览、复制与下载共用同一份 JSON 字符串（`ShareJSON/index.tsx:87`），保证预览所见即所得。
- **分享是实时非快照**：与"快照分享"路线相反，服务端在每次访问时以属主身份现读；`skipWorks` 是唯一的内容治理点。这也意味着源 topic 后续变化会直接反映到已分享链接。
- **OSS/云能力分层**：RBAC 与 `usePermission` 在 OSS 是放行桩（`src/hooks/usePermission.ts:12-15`），`enableBusinessFeatures` 是硬开关；链接分享 UI 默认隐藏，服务端与路由代码齐备。导出弹窗不受开关影响。
- 单消息分享仅助手消息（`share.tsx:16`），文本仅拼 content、无角色标题（`ShareMessageModal/ShareText/template.ts:10-14`）。

## 12. 未验证事项

- 运行验证缺失：snapdom 对无 CORS 头远端图片的实际成像/污染表现、`proxy.corsfix.com` 代理可用性；PDF 的 jsdelivr 字体下载可达性及超长内容行为；剪贴板 PNG 的浏览器兼容性（`ClipboardItem`）；Electron 下的导出/分享表现。
- 链接分享的实际 HTTP 语义：匿名访问 private 分享的 FORBIDDEN 表现、删除分享后 URL 的 404 表现、`pageViewCount` 计数行为——代码可确认但未运行。
- 云版（`ENABLE_BUSINESS_FEATURES=true`）下 SharePopover 全流程与 workspace 权限矩阵（`withScopedPermission` 云版实现不在本仓库）。
- 分享页"实时"语义的边界：源 topic 消息变更后访客看到的实际刷新行为；`findByShareIdWithAccessCheck` 中 owner 判定依赖 `ctx.userId`，匿名+private 时必然拒绝。
- topic 复制后消息文件关联缺失的 UI 实际表现（消息内 `/f/:id` 图片仍可加载，但附件列表芯片可能缺失——静态推断）。
- `importTopic` 对 simple 数组自动补的线性 parentId 链、以及 full 导出中未覆盖字段（如 `files`）被 `ImportedMessage` schema 静默丢弃后的实际效果。
- 本次未覆盖：`/share/page` 文档分享、社区市场发布、整库导出 `exporter.exportData`（`apps/server/src/routers/lambda/exporter.ts:176-180`，owner-only 的 DB 级备份，属会话与消息管理类目）。

## 13. 关键源码索引

- `src/features/ShareModal/`（Modal.tsx 四 Tab、ShareDataProvider、ShareImage、ShareText、SharePdf、ShareJSON、tabRegistry）
- `src/features/ShareModal/ShareImage/ChatList/index.tsx`、`Preview.tsx`（分享版式与成像 DOM）
- `src/hooks/useScreenshot.ts`、`src/hooks/useImgToClipboard.ts`（snapdom 成像、DPR、CORS 代理、复制/下载）
- `src/features/SharePopover/index.tsx`（链接分享 UI、可见性、隐私提醒）
- `src/routes/(main)/agent/features/Conversation/Header/ShareButton/index.tsx`（入口与 business 开关）
- `src/features/Conversation/components/ShareMessageModal/`（单消息分享）
- `src/store/chat/slices/topic/action.ts`（duplicateTopic 238、importTopic 256）、`src/services/topic/index.ts`
- `apps/server/src/routers/lambda/topic.ts`（cloneTopic 345、importTopic 641、share 操作 412-458/871-894）、`apps/server/src/routers/lambda/share.ts`、`apps/server/src/routers/lambda/message.ts:347-411`
- `apps/server/src/routers/lambda/exporter.ts`（exportPdf 182、exportData 176）
- `packages/database/src/models/topic.ts:1086`（duplicate）、`packages/database/src/models/topicShare.ts`、`packages/database/src/repositories/topicImporter/index.ts`、`packages/database/src/schemas/topic.ts:231`
- `packages/database/src/utils/copyMessagesInDatabase.ts`、`copiedTranscript.ts`
- `packages/types/src/export.ts`（ExportedTopic/ImportedMessage）、`packages/types/src/topic/topic.ts:685`（SharedTopicData）
- `src/routes/share/t/[id]/`（分享页）、`src/app/(backend)/f/[id]/route.ts`（文件代理）、`packages/business/const/src/index.ts:7`（ENABLE_BUSINESS_FEATURES）
