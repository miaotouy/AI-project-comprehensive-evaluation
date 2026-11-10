# LobeHub 对话导出与分享调查笔记

> 调查对象：`https://github.com/lobehub/lobehub`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`67aaf17da1f43f0b5c851794b796a92d3258b86b`（分支：`canary`）
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

分享页由独立 SPA 承载（vite + react-router），按共享对象分为 topic、page、file、artifact 四类视图，公共外壳放在 `src/business/client/features/ShareShell`。主应用 `src/routes` 下不注册 `/share/t/:id` 路由；topic 分享的视图组件与路由表都在 `apps/share/src/{router.tsx,features/topic/}`。

工作区本地文件另出现一条不经 Topic Share 的公开交付链：HTML 预览和文件树可发起发布，收集 HTML/CSS/JS 引用的本地资源，32 KB 以下资源内联，其他资源作为静态站点 sidecar；系统拒绝遗留的本地引用，并在收集期限制为最多 64 个文件、单文件及总量各不超过 50 MB。打包后的 HTML 先写成 Artifact 消息，再交给业务发布槽生成公开地址；开源默认槽会报告发布不可用，因此本地文件发布链能否产出公开地址取决于所配置的业务发布槽，入口可见性只说明 UI 暴露了发布动作（`src/features/Portal/LocalFile/{prepareWorkspaceHtmlPublish,publishWorkspaceHtmlArtifact,readWorkspaceAsset}.ts`）。

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
  -> 访客打开 /share/t/:id -> 由 apps/share 独立 SPA 承载
    -> share.getSharedTopic（publicProcedure，校验 visibility）
    -> message.getMessages(topicShareId)（以 share 属主身份实时读源 topic 消息）
    -> SharedTopicView/SharedMessageList 渲染 + 附件经 /f/:id 公开文件代理
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

- **范围**：导出取当前 topic 的全部消息，顺序沿用服务端返回的顺序；弹窗不提供选区、区间起点或分支选择。打开分享弹窗时以 `threadId: null` 进入，只导出主链消息，线程内的回复不在其中；单消息分享只取被点开的那一条（`useDropdownMenu.tsx:93`、`ShareMessageModal/ShareText/index.tsx:25`）。
- **内容口径**：三条路径的取数来源不同：
  - 截图与分享页直接复用聊天现场的 `MessageItem` 渲染，结果与聊天时所见的表达一致（`src/features/ShareModal/ShareImage/ChatList/index.tsx:23-25`、`src/routes/share/t/[id]/SharedMessageList.tsx:37-40`）；
  - 文本与 PDF 从 `displayMessages` 的 content 字段拼接（`ShareText/template.ts:13-61`）；
  - JSON full 从 `dbMessages` 逐字段投影。
- **system/reasoning/工具**：文本导出对角色、system prompt、思考内容与工具消息分别处理：
  - 角色与工具：默认开启 `withRole`，按 User、Assistant、Tools Calling 输出三级标题，工具消息内容包进 JSON 代码块；工具消息与用户消息可分别用 `includeTool`、`includeUser` 关闭；
  - system prompt：由 `withSystemRole` 开关控制，多个入口默认关闭，JSON 导出默认开启；
  - reasoning 与 artifact：思考内容不会被剥离，`<think>`/`<lobeThinking>` 与 artifact 标记结构都会原样保留，预处理由 normalizeThinkTags 规整换行、processWithArtifact 处理 artifact 标记；
  - 占位消息：加载态占位消息（`LOADING_FLAT`）在导出前被过滤。
  以上模板逻辑集中在 `ShareText/template.ts:29-58`，artifact 预处理见 `src/features/Conversation/utils/markdown.ts:19-96`。
- **隐藏分支**：本次未找到导出隐藏分支或全部版本内容的路径，`generateFullExport` 按消息数组原样输出，不区分活动路径与旁支（`ShareJSON/generateFullExport.ts:23-52`）。

## 3. 附件、资源与离线封装

- **JSON full**：每条消息各输出 content、plugin、pluginState、tools、reasoning 与 metadata 六个字段；消息模型查询时拼接的 `files` 附件数组不写入文件，因此附件不会进入任何导出格式（`ShareJSON/generateFullExport.ts:26-51`）。
- **Markdown/PDF**：消息正文里的图片 Markdown 链接按原文保留，通常就是 `/f/:id` 形式的访问地址，导出过程不做内联或代理转换，离线打开时这些引用会失效。PDF 在服务端渲染，图片与表格 token 直接按文本输出（见 §6）。
- **截图**：成像、代理与头部渲染各有一处固定行为：
  - `snapdom` 对 DOM 成像时会把页面引用的资源内联进去，它来自 `@zumer/snapdom` ^1.9.14，是 package.json 的顶层依赖；
  - 栅格格式导出时，跨域图片经 `useProxy: 'https://proxy.corsfix.com/?'` 代理加载（`src/hooks/useScreenshot.ts:54-57`）；
  - 分享版式头部渲染模型与插件标签，`withPluginInfo` 默认关闭（`ShareImage/Preview.tsx:115-120`）。
- **分享页附件**：服务端返回消息时会把文件 URL 改写成访问地址，生产环境下该地址指向 `/f/:id` 公开代理；这个端点在注释里写明 intentionally unauthenticated，按文件 id 公开访问并 302 到预签名 URL，改写与代理分别见 `apps/server/src/routers/lambda/message.ts:393-395`、`apps/server/src/services/file/index.ts:128-136` 与 `src/app/(backend)/f/[id]/route.ts:20-23`。该路由挂在 web 壳上，Electron 桌面端没有注册分享路由。

## 4. 格式、schema 与往返能力

- **Markdown**：文件名为 `<title>.md`，内容依次是一级标题、每个角色的三级标题与正文，不带版本号；四种格式里只有 JSON 能再被导入（`ShareText/template.ts:22-61`）。
- **JSON**：侧栏可在 simple 与 full 两种模式间切换，模式类型是 `TopicExportMode`（`packages/types/src/export.ts:20`）：
  - simple 输出 `{role, content}` 数组，可在开头补一条 system 消息，并带 `tool_call_id` 与 `tools` 字段（`ShareJSON/generateMessages.ts:11-36`）；
  - full 输出 `ExportedTopic` 结构，含 version 2.0、title、exportedAt 与 messages 数组（`ShareJSON/generateFullExport.ts:66-71`、`packages/types/src/export.ts:26-35`）。
- **往返**：full 与 simple 两种文件都能通过"Topic 列表 -> 导入 .json"回到服务端的导入入口，入口在 `apps/server/src/routers/lambda/topic.ts:641-662`。`TopicImporterRepo` 的实际处理如下：
  - 按 `version` 键是否存在区分格式，版本值本身不做校验；
  - 导入时过滤 system 消息、重建 `parentId` 链、重新生成消息 ID，并把插件写入 `messagePlugins`；
  - 没有 parentId 的简单数组按数组顺序补成线性链；
  - 文件关联、翻译、TTS 与压缩组不参与导入，往返语义成立但结果有损。
  上述实现见 `packages/database/src/repositories/topicImporter/index.ts:77-241`。
- **导出内容与分享稿的关系**：schema 里没有分享稿对象，导出结果就是当前数据的一次投影。

## 5. 分享稿编辑、编排与预览

- 截图 Tab：版式独立于聊天界面，含品牌头像、标题、模型标签、可选 system role 区、消息列表与可选页脚品牌区（`ShareImage/Preview.tsx:89-140`）。实时预览与生成物出自同一个 DOM（`id="preview"`），生成时直接对该节点成像，没有另建渲染管线。版式可配置项共六个：
  - `widthMode`：版式宽度，窄版 480px 或宽版 100%；
  - `withBackground`：是否绘制装饰背景；
  - `withFooter`：是否显示页脚品牌区；
  - `withSystemRole`：是否显示 system role 区；
  - `withPluginInfo`：是否显示头部模型与插件标签；
  - `imageType`：输出图片格式。
  宽度与背景样式的实现分别在 `src/features/ShareModal/useContainerStyles.ts:36-43` 和 `ShareImage/style.ts:6-13`。
- 文本与 JSON Tab：侧栏选项加预览区，文本预览走 Markdown 渲染，JSON 预览显示缩进文本；复制与下载共用同一份 content 字符串（`ShareText/index.tsx:64-98`、`ShareJSON/index.tsx:87-115`）。
- 移动端布局：选项表单折叠到底部按钮区，判断依据是各 Tab 组件里的 `isMobile` 分支。
- 本次未找到：自定义字体、分页、水印、品牌覆盖、元信息编辑或分享稿工作台。

## 6. 图片、HTML、PDF 与富内容生成

- **截图**：成像、复制与下载三条行为固定，另有尺寸处理上的边界：
  - 成像由 `useScreenshot` 调 `snapdom`（html-to-image 系 fork）对预览节点完成，DPR 固定为 2；SVG 用 `toRaw` 导出，栅格图用 `toBlob`；
  - 复制成 PNG 时把 blob 包成 `ClipboardItem`，再写入系统剪贴板；
  - 下载走 data URL 与 `<a download>`，文件名按 `${BRANDING_NAME}_${title}_${date}.${ext}` 模板生成；
  - 长图不做分段拼接，Canvas 尺寸上限也没有处理代码。
  成像、复制与命名的实现分别在 `src/hooks/useScreenshot.ts:39-64`、`src/hooks/useImgToClipboard.ts:13-24` 与 `useScreenshot.ts:102-115`。
- **PDF**：由服务端 `exporter.exportPdf` 生成：
  - 渲染先用 `marked` 的 lexer 分词，再由 `pdfkit` 逐 token 排版标题、段落、列表、引用、代码与分隔线，页面为 A4、50px 边距并带页码；
  - 中文字体在运行时从 jsdelivr CDN 下载 Source Han Sans，下载失败直接抛错；
  - 图片、表格、数学公式、Mermaid 与行内代码高亮都不处理，相应 token 按纯文本输出；
  - OSS 下的 RBAC 中间件是放行桩，登录用户即可调用。
  PDF 路由入口与内部排版、字体加载的实现见 `apps/server/src/routers/lambda/exporter.ts:30-198`，RBAC 桩见 `packages/business-server/src/trpc-middlewares/rbacPermission.ts:14-28`。
- **富内容保真**：截图与分享页直接复用聊天现场的 `MessageItem` 与 `ChatList` 渲染器，Markdown、工具卡、Artifact、图片等现场表达都会出现在结果里；文本导出回到纯 Markdown，工具调用以 tools 字段的 JSON 代码块呈现（`ShareText/template.ts:55-58`）；PDF 只有纯文本流，保真度最低。

## 7. 生成历史、版本与持久化

- 截图/文本/JSON：每次点击复制/下载即时生成，无历史列表；选项变化重渲染即得新结果。
- PDF：`usePdfGeneration` 有"生成/重新生成"按钮，但 `pdfData` 只存在组件状态，重新生成覆盖（`SharePdf/usePdfGeneration.ts:20-53`），关闭弹窗即丢失，无版本对比或持久化。
- 分享链接：`topic_shares` 一条记录对应一个 topic（`topicId` 唯一索引），没有同一分享的多版本；分享页展示的是源 topic 实时数据（见 §8），"更新"即源 topic 本身的变化。

## 8. 分享载体、访问控制与撤销

- **载体**：分享记录存放在 `topic_shares` 表，一条记录对应一个 topic 的一次分享（`packages/database/src/schemas/topic.ts:231-258`）：
  - `shareId` 是 8 位 nanoId，作为公开访问地址里的标识；
  - `visibility` 默认取 `'private'`，切成 link 后才对外可见；
  - `pageViewCount` 累计分享页的访问次数；
  - 删除 topic 时分享记录随之级联删除。
- **创建/更新**：服务端把建、改、删三个操作放在 topic 路由里，模型实现见 `packages/database/src/models/topicShare.ts:43-116`，路由入口见 `apps/server/src/routers/lambda/topic.ts:412-458,871-894`：
  - `enableSharing` 负责建记录，靠 `onConflictDoNothing` 保持幂等；
  - `updateShareVisibility` 在 private 与 link 之间切换；
  - `disableSharing` 删除记录。
  SharePopover 打开时如果还没有记录，会创建一条 private 分享；用户把可见性切到 link 时，界面自动复制链接并给出 toast，同时弹出隐私提醒，覆盖工具调用、凭据、图片与文件四类内容（`src/features/SharePopover/index.tsx:80-160`）。
- **访问语义**：能否读取分享由访问检查判定，private 只允许属主本人，link 对所有人开放（`packages/database/src/models/topicShare.ts:214-235`）。公开读取入口挂在 tRPC 的公开过程上，匿名免登录即可调用；返回分享元数据时顺带自增访问计数，见 `apps/server/src/routers/lambda/share.ts:14-56`。消息本身由消息查询以分享属主身份实时读出，并跳过运行中的 Work 状态，相关读取见 `apps/server/src/routers/lambda/message.ts:347-411`。
- **快照 vs 实时**：分享页每次请求都读源 topic 的当前消息，属于实时展示。创建分享时保存的是主题关联、属主、可见性与工作区等信息；标题与 Agent 元数据在读取分享时关联当前的主题表和 Agent 表取得，也会随源数据变化（`packages/database/src/models/topicShare.ts:57-67,123-155`）。
- **撤销/删除**：`disableSharing` 删除记录后，原 shareId 无法再解析，公开访问返回 NOT_FOUND；本次未找到调用它的客户端入口，SharePopover 只提供 private/link 选择器，切回 private 就对非属主隐藏，记录本身保留。workspace 模式下分享管理限创建者或 workspace owner，并写入 `resource.shared`/`resource.unshared` 审计日志（`apps/server/src/routers/lambda/topic.ts:98-142`）。
- **入口开关**：配置从 OSS 常量 `ENABLE_BUSINESS_FEATURES = false` 出发，经服务端下发到前端，SharePopover 仅在开关为真时挂载（`packages/business/const/src/index.ts:7`、`apps/server/src/globalConfig/getServerAuthConfig.ts:16`、`ShareButton/index.tsx:27,50-54`）。链接分享的服务端与页面代码都在本仓库，OSS 自托管默认只是从界面隐藏入口，云版直接覆盖这个开关。
- **分享页**：由独立 SPA `apps/share` 承载，Web 与移动端访问同一地址，Electron 是否内嵌尚未验证：
  - 路由入口在 `apps/share/src/router.tsx`，按 topic、page、file、artifact 分路由，外壳复用 `ShareShell`；
  - topic 分享正文用 `apps/share/src/features/topic/` 下的消息列表组件，以 `topicShareId` 上下文拉取消息；
  - 页面禁用编辑与操作条，页脚显示免责声明（`sharePageDisclaimer`）。
  `/share/page/:id` 是文档对象分享，由同一 SPA 的 `SharedPageView` 承载。

## 9. 隐私、安全与内容治理

- 从 private 切到 link 时会弹出隐私提醒，说明工具调用、凭据、图片与文件四类内容可能随分享暴露，并提供"不再提醒"选项，选择结果持久化到 systemStatus（`src/features/SharePopover/index.tsx:113-160`，同一文件的开关读写见 `:41-46`）。导出弹窗没有敏感内容扫描或过滤，直接按当前数据生成文件。
- reasoning/think 内容在文本导出中保留（`normalizeThinkTags` 只重排换行不剥离）；system role 由 `withSystemRole` 开关控制（默认 off，JSON 默认 on）。
- 分享页把文件 URL 经 `getFileAccessUrl` 改写为 `/f/:id` 形式。这个代理不校验身份、按文件 id 公开访问，知道 id 就能取到文件，属于既有设计（`src/app/(backend)/f/[id]/route.ts`）。服务端在拼接消息时会对失去访问权的文件返回空 URL，防止泄漏（`packages/database/src/models/message.ts:1097-1105` 一带）。
- PDF 由服务端从 Markdown 纯文本渲染，无脚本执行面；截图/分享页是客户端自渲染 DOM，不引入外部 HTML。
- 本次未找到导出中的水印、密钥/个人信息扫描、文件名净化逻辑。

## 10. 性能、失败恢复与测试

- 失败反馈：三条路径给出的反馈层级不同：
  - 截图复制与下载失败时只写一条 `console.error`，界面没有其他提示（`src/hooks/useScreenshot.ts:111-114`、`src/hooks/useImgToClipboard.ts:21-24`）；
  - PDF 生成失败会在弹窗里显示错误块和错误描述，用户可以直接重试（`SharePdf/index.tsx:146-170`）；
  - importTopic 失败会弹出导入错误提示，并把导入状态复位（`src/store/chat/slices/topic/action.ts:277-282`）。
- 长会话：截图不做分段拼接；PDF 会逐 token 换页，但没有页数上限的控制代码；分享页读取消息支持 `limit/offset` 分页，入口是 `topic.ts:153-183` 的 `getTopicTranscript`。
- 测试：`apps/server/src/routers/lambda/__tests__/integration/topicShare.integration.test.ts`（enable/update/disable 的属主与越权矩阵）、`topic.integration.test.ts` 的 cloneTopic 用例、`topic.test.ts` 的 share 各方法 mock 用例；PDF/截图生成未见自动化测试。运行验证（图片保真、字体 CDN、跨域代理、剪贴板、匿名访问）本次均未执行。

## 11. 设计取舍与已确认边界

- **站内操作与对外交付分离**：复制、导入与转发都在数据库内部完成，不产生交付文件。复制走 `cloneTopic`，导入走 `importTopic`；转发最轻，它把整个 topic 的转录拼成一条用户消息，作为新对话的首条消息发给另一个 agent，既不建副本也不写文件（`src/store/chat/slices/forward/action.ts:99-106`）。
- **复制语义**：新 topic 在本位继承归属信息，用量与消息则分别重置和重写，整体实现见 `packages/database/src/models/topic.ts:1086-1198`：
  - 继承：`agentId`、`groupId` 与 `sessionId` 保持原值；
  - 用量重置：usage 汇总按 `COPIED_TOPIC_USAGE_RESET` 清零，token 与 cost 数字本身保留，报表另按 copied 标记过滤（`copiedTranscript.ts:36-62`）；
  - 消息重写：生成新 id、按映射重建 `parentId` 链，tools 的 id 与插件的 `toolCallId` 一并换新，并写入 `metadata.copied: true`（`copyMessagesInDatabase.ts:32-38`）；
  - 不复制：文件关联、翻译、TTS、压缩组与 chunks/queries。SQL 版消息复制覆盖全部子表（`copyMessagesInDatabase.ts:253-304`），topic 复制只处理主表与插件，口径更轻。
- **导出四格式共用同一数据源与一致的预览-产物**：截图预览本身就是产物；文本与 PDF 共用 `generateMarkdown` 生成的同一份 content 字符串；JSON 的预览、复制与下载也共用同一份 JSON 字符串（`ShareJSON/index.tsx:87`）。
- **分享是实时读取**：服务端在每次访问时以分享属主身份重新读取源 topic，`skipWorks` 是唯一的内容治理点；已分享链接展示的始终是源 topic 的当前内容。
- **OSS/云能力分层**：RBAC 与 `usePermission` 在 OSS 里是放行桩（`src/hooks/usePermission.ts:12-15`），`enableBusinessFeatures` 决定链接分享界面是否挂载；服务端与路由代码在 OSS 版本中同样齐全，默认只是从界面隐藏入口。导出弹窗不受这个开关影响。
- 单消息分享只对助手消息开放（`share.tsx:16`），导出的文本只拼 content，不带角色标题（`ShareMessageModal/ShareText/template.ts:10-14`）。

## 12. 未验证事项

- 运行验证缺失：snapdom 处理没有 CORS 头的远端图片时实际成像如何、是否污染画布，以及 `proxy.corsfix.com` 代理当前是否可用；PDF 依赖的 jsdelivr 字体能否下载、超长内容如何排版；`ClipboardItem` 写入 PNG 在主流浏览器上的兼容性；Electron 下的导出与分享表现。
- 链接分享的实际 HTTP 语义只能从代码确认，尚未运行验证：匿名访客打开 private 分享时的拒绝响应、删除分享后 URL 的 404 表现，以及 `pageViewCount` 的自增行为。
- 云版（`ENABLE_BUSINESS_FEATURES=true`）下 SharePopover 的完整流程与 workspace 权限矩阵未验证，云端 `withScopedPermission` 的实现不在本仓库。
- 分享页"实时"语义的边界：源 topic 消息变化后访客端实际的刷新行为未观察；权限判定依赖 `ctx.userId`，匿名访问 private 分享必然被拒绝。
- topic 复制后消息文件关联缺失在界面上的实际表现只有静态推断：消息内的 `/f/:id` 图片仍可加载，附件列表里的芯片可能缺失。
- 导入端对 simple 数组自动补线性 parentId 链、full 导出中未覆盖的字段被 `ImportedMessage` schema 静默丢弃，这两点在数据与界面上产生的实际效果尚未验证。
- 本次未覆盖社区市场发布与整库导出：`exporter.exportData` 是 owner-only 的 DB 级备份，属于会话与消息管理类目，实现见 `apps/server/src/routers/lambda/exporter.ts`。
- `apps/share` 独立 SPA 的部署形态尚未运行验证，包括是否与主 Web 同域、路由如何重写、Electron 内分享页的行为，以及主应用与分享应用之间的 shell 共享边界。
- 本轮按引用路径核对了分享入口（`topic/share.ts`、`apps/share`）与数据模型拆分（`models/topic/`、`models/message/`、`repositories/topic/`），未逐行重读导出模板与 PDF 渲染；行号引用以模块级定位为准。

## 13. 关键源码索引

- `src/features/ShareModal/`（Modal.tsx 四 Tab、ShareDataProvider、ShareImage、ShareText、SharePdf、ShareJSON、tabRegistry）
- `src/features/ShareModal/ShareImage/ChatList/index.tsx`、`Preview.tsx`（分享版式与成像 DOM）
- `src/hooks/useScreenshot.ts`、`src/hooks/useImgToClipboard.ts`（snapdom 成像、DPR、CORS 代理、复制/下载）
- `src/features/SharePopover/index.tsx`（链接分享 UI、可见性、隐私提醒）
- `src/routes/(main)/agent/features/Conversation/Header/ShareButton/index.tsx`（入口与 business 开关）
- `src/features/Conversation/components/ShareMessageModal/`（单消息分享）
- `src/store/chat/slices/topic/action.ts`（`duplicateTopic`/`importTopic`）、`src/services/topic/index.ts`
- `apps/server/src/routers/lambda/topic/`（`create.ts` 的 import、`share.ts` 的 enable/update/disable）、`routers/lambda/share.ts`、`routers/lambda/message.ts`（`topicShareId` 读取）
- `apps/server/src/routers/lambda/exporter.ts`（`exportPdf`/`exportData`）
- `packages/database/src/repositories/topic/duplicate.ts`（topic 复制）、`packages/database/src/models/topicShare.ts`、`packages/database/src/repositories/topicImporter/index.ts`、`packages/database/src/schemas/topic.ts`（topic_shares 表）
- `packages/database/src/utils/copyMessagesInDatabase.ts`、`copiedTranscript.ts`
- `packages/types/src/export.ts`（ExportedTopic/ImportedMessage）、`packages/types/src/topic/topic.ts`（SharedTopicData）
- `apps/share/src/router.tsx`、`apps/share/src/features/topic/`（分享页 SPA）、`src/business/client/features/ShareShell`（共享外壳）、`src/app/(backend)/f/[id]/route.ts`（文件代理）、`packages/business/const/src/index.ts`（ENABLE_BUSINESS_FEATURES）
- 框架与平台入口：`packages/trpc/src/lambda/index.ts:34`（publicProcedure）、`src/spa/router/desktopRouter.sync.test.tsx:199-207`（Electron 未注册分享路由）
