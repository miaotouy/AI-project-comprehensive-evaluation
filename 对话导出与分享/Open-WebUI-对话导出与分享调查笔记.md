# Open WebUI 对话导出与分享调查笔记

> 调查对象：`https://github.com/open-webui/open-webui`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`c38885a1a737da4968f157092f304f3b5481d0bf`（分支：`main`）
>
> 调查方式：静态源码调查（未运行应用）；追踪聊天页与侧边栏的导出/分享入口、PDF 两种生成路径、/s 分享页、后端 share 端点与 shared_chat 快照表、access_grants 权限模型、社区分享与统计导出、DataControls 的 JSON 往返；未运行浏览器与后端服务
>
> 调查范围：单会话的下载（JSON/TXT/PDF）与链接分享（/s 快照页）、访问控制、撤销与克隆、社区分享交接、全量 JSON 导出导入往返；不覆盖 Notes/Artifact/Knowledge 等对象自身的导出、数据库整库备份、消息级复制按钮
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI 的对话导出与分享分成两条独立主链：本地文件下载（JSON / TXT / PDF）和站内链接分享（`/s/{share_id}` 快照页）。两条链的入口同时存在于聊天页导航栏与侧边栏会话菜单，共用 `chat.export` / `chat.share` 权限门。

PDF 有两种模式，由用户设置 `stylizedPdfExport`（默认 true）切换。该设置只控制呈现方式，与“当前视图 vs 完整对话”的范围无关：样式模式用隐藏的全消息容器 + 离屏 DOM 克隆 + `html2canvas-pro` 整段渲染 + jsPDF 按 A4 比例切条分页；纯文本模式用 jsPDF 的 `splitTextToSize` 排 Markdown 文本。另有第三个实现：后端 `/utils/pdf`（fpdf2）与前端包装 `downloadChatAsPDF`，本次未找到任何调用点。

链接分享采用快照语义：调用 `POST /chats/{id}/share` 时，后端把整个会话 JSON 复制进 `shared_chat` 表，并以 UUID 作为分享 token。站内分享页 `/s/{share_id}` 读取的是这份快照副本，再次调用同一接口会对同一 URL 重拍快照。可见性分 private、public、open 三档，由 `access_grants` 上的 `read` 授权决定，其中 open 档允许匿名访问。删除、撤销全部、共享列表管理与克隆入口均已具备。快照只复制会话 JSON，附件仍通过需登录的 `/files/{id}/content` 提供。

社区路径是纯前端交接：弹窗用 `window.postMessage` 把聊天 JSON 交给第三方站点 openwebui.com 的 `/chats/upload`，本仓库没有服务端提交或发现机制；`/s` 页面带 `noindex,nofollow`，未发现公开目录或搜索索引。

## 系统边界与完整主链

```text
下载链（本地交付物）：
  Sidebar/ChatMenu 或 Navbar/Menu（聊天页）
    -> getChatById 取 ChatResponse
    -> JSON：JSON.stringify([chat]) -> chat-export-<ts>.json
    -> TXT：getOutputText(output) || content 拼 Markdown -> chat-<title>.txt
    -> PDF：stylizedPdfExport
           true  -> 隐藏容器 #full-messages-container 渲染 Messages
                    -> cloneNode 离屏克隆 -> html2canvas-pro（scale 2）
                    -> jsPDF A4 纵向切条 -> chat-<title>.pdf
           false -> jsPDF splitTextToSize 纯文本排版

分享链（站内快照链接）：
  ShareChatModal.shareLocalChat
    -> POST /api/v1/chats/{id}/share
    -> SharedChats.create/update：shared_chat 表（id=uuid4, chat=chat.chat 快照）
    -> chat.share_id 写回源会话
    -> URL = origin/s/{share_id}
    -> GET /api/v1/chats/share/{share_id}（get_optional_verified_user）
    -> 权限判断：open(anyone:*)/public(user:*)/指定用户组
    -> 返回快照 ChatModel 视图 -> /s/[id] 页面 readOnly 渲染

社区链（第三方交接，E5 弱）：
  ShareChatModal.shareChat -> window.open(openwebui.com/chats/upload)
    -> postMessage({chat, models})，无本仓库服务端参与
```

## 1. 入口、用户目标与导出源

入口分三层（均为会话级，无单消息导出）：

- 聊天页导航栏：Share 与 Download 子菜单（Export chat (.json)、Plain text (.txt)、PDF document (.pdf)），另有 Copy 项（`Navbar/Menu.svelte:369-443`）；
- 侧边栏会话菜单：提供同样的 Share、Download 子菜单，以及 Clone、Archive 等会话操作（`ChatMenu.svelte:306-360`）；
- 设置页 DataControls：负责全量 JSON 导出与导入，并托管 "Shared Chats" 管理弹窗（`Settings/DataControls.svelte:90-95`、`SharedChatsModal.svelte`）。

导出源是单个会话。顺序与范围由 `createMessagesList`（`src/lib/utils/index.ts:1404-1418`）决定：沿 `parentId` 从当前消息回溯到根再反转，即只包含活动分支路径，不包含隐藏分支；JSON 导出例外，它导出整个 `ChatResponse`（含完整 history 树），只是下载层面不做任何裁剪。

权限门：分享按钮要求 admin 或 `user.permissions.chat.share` 权限（前端 `Menu.svelte:369`），后端在分享接口再校验一次（`backend/open_webui/routers/chats.py:1940`）。导出对应 `chat.export` 权限（`ChatMenu.svelte:319`）。

环境变量默认值：`USER_PERMISSIONS_CHAT_SHARE/EXPORT/IMPORT` 三个权限开关默认开启，公开与开放分享（`ALLOW_PUBLIC_SHARING`/`ALLOW_OPEN_SHARING`）默认关闭（`backend/open_webui/config.py:1854-1866`）。

## 2. 范围选择、内容口径与字段过滤

- TXT：两个菜单组件的实现一致，都按 `### 角色` 标题加正文的格式逐条拼接消息。正文优先取 `getOutputText` 返回的 message 类型片段，没有 output 时退回消息原始 content。这条路径没有像聊天渲染那样先剥离 details 块，content 中的 `<details type="reasoning">` 等标记会原样写进 TXT 与纯文本 PDF。以上为静态代码结论，reasoning 在消息记录中的实际落库形态未运行确认。实现见 `ChatMenu.svelte:64-87` 与 `Messages/structuredOutput.ts:335-341`；渲染侧先剥离 details 的入口是 `ResponseMessage.svelte:189`。
- JSON：`JSON.stringify([chat])` 导出完整 `ChatResponse`（id、user_id、title、chat、share_id、archived、meta、variables、folder_id 等，`backend/open_webui/models/chats.py:201-218`），无字段裁剪、无脱敏。
- 快照分享：`SharedChats.create` 把整个会话 JSON（含 history、messages、params、system 等）复制到 shared_chat 表的内容列（`backend/open_webui/models/shared_chats.py:60-89`），不做任何内容过滤。
- 全量导出：`GET /chats/all` 以 NDJSON 流式输出；`GET /chats/all/db` 另受 admin 与 `ENABLE_ADMIN_EXPORT` 门控（`chats.py:988-993,1029-1033`）。
- 隐藏分支：TXT/PDF 只覆盖活动分支；JSON 与快照包含完整树但展示端（`createMessagesList`）只渲染活动分支。没有任何导出路径提供分支选择器或逐条勾选（对比 NextChat 的 MessageSelector）。

## 3. 附件、资源与离线封装

- TXT / 纯文本 PDF：附件不进入文本，图片引用作为 Markdown 文本保留。
- 样式化 PDF：捕获的是完整消息列表的渲染结果，消息内嵌图片会进入 canvas。`html2canvas-pro` 开启了 `useCORS`，跨域图片缺少 CORS 头时仍可能污染 canvas（基于库行为的推断，未运行验证）。
- JSON：保留 `files`、`embeds` 等字段引用，不打包文件本体。
- 分享快照页：前端按文件 ID 请求 `/api/v1/files/{id}/content` 加载附件，该端点要求登录并校验文件归属或授权，授权对象是文件自身，分享快照不参与附件授权。因此 open 档分享页的匿名访客能否看到附件，取决于文件是否另有公开授权，这一点为静态推断，未运行验证。PDF 与 TXT 均不打包资源，离线打开时无法保证附件可用。附件端点的实现见 `backend/open_webui/routers/files.py:782-842`。

## 4. 格式、schema 与往返能力

- JSON：单会话导出的数组结构与全量导出一致，可以经 DataControls 的导入入口或侧边栏拖拽完成往返；导入端兼容 OpenAI 的导出格式。导出结果就是服务端 Chat 模型接受的原始结构，字段比精简的 messages 载荷更全，往返语义在单仓库内闭合。整库迁移与配置导出（`/configs/export`）不在本类目。导入端点见 `POST /chats/import`（`chats.py:788-809`），前端格式兼容逻辑见 `DataControls.svelte:42-48`。
- TXT：面向阅读的 Markdown 风格文本，无 schema，无导入路径。
- PDF：A4 竖版 JPEG 光栅页（样式模式）或纯文本页（文本模式），无书签/元数据/可复制文本（样式模式）。
- 统计导出（社区相关）：`GET /chats/stats/export` 返回 JSON 分页或 NDJSON 流，条目为含完整会话的 `ChatStatsExport` 结构。该端点受 `ui.enable_community_sharing` 门控（`chats.py:581-619`）。

## 5. 分享稿编辑、编排与预览

不适用。没有独立于聊天现场的分享稿编辑器或预览表面：TXT/JSON 直接生成；样式化 PDF 直接渲染隐藏容器中的聊天 `Messages` 组件；分享弹窗（`ShareChatModal.svelte`）只做链接创建、访问权限编辑与删除，不提供内容选区、顺序调整、水印、主题或分页预览。唯一的"编排"开关是全局设置 `stylizedPdfExport`（Interface 设置页，`Settings/Interface.svelte:1183-1199`）。

## 6. 图片、HTML、PDF 与富内容生成

PDF 是唯一的文档生成能力，两个菜单组件实现逐行相同（`Navbar/Menu.svelte:81-240`、`Sidebar/ChatMenu.svelte:89-253`）：

- 样式模式（默认）：先以只读模式渲染隐藏的全消息容器，把克隆体挂到 body 外的离屏位置（绝对定位、固定宽 800px），并强制消息项内容可见以对抗聊天列表的渲染优化；随后 html2canvas-pro 按暗色主题、2 倍缩放整段捕获，jsPDF 按 A4 折算每页像素高，把整张 canvas 切成等高条，每条以 JPEG 格式逐页加入，暗色模式先铺黑底矩形（`Menu.svelte:138-197`）。
- 文本模式（`stylizedPdfExport=false`）：取 TXT 文本，交给 jsPDF 用 `splitTextToSize` 以 8pt 字号换行分页。
- 富内容保真：样式模式复用聊天现场渲染器，reasoning 折叠块、工具卡、代码高亮、数学公式与表格的呈现与屏幕一致，不需要专门降级；文本模式把这些内容退化为纯文本。
- 生成位置：PDF 只在浏览器端生成。后端 `routers/utils.py` 只剩 gravatar、代码格式化、代码执行与数据库下载四个端点，仓库内已无 fpdf 依赖和 `pdf_generator` 模块。笔记导出复用同一套 jsPDF 与 html2canvas-pro 实现（`src/lib/components/notes/utils.ts:61`）。
- 无图片/PNG 导出、无分享图生成（对比 NextChat 的 E3 图片链，Open WebUI 本次未找到）。

## 7. 生成历史、版本与持久化

不适用。重新生成即重新下载，无结果列表。分享侧"重新生成"是覆盖语义：`POST /chats/{id}/share` 在 `chat.share_id` 已存在时走更新路径重拍快照并保留同一 URL（`chats.py:1947-1959`）；UI 上表现为"Update and Copy Link"按钮（`ShareChatModal.svelte:220-224`）。旧快照不保留（除非源会话自身分支）。无分享版本历史、无过期时间设置。

## 8. 分享载体、访问控制与撤销

- 载体：分享链接是站内快照地址，形如 `{origin}/s/{uuid4}`，token 为 UUID，没有可枚举的目录。分享页 `/s/[id]` 没有服务端加载逻辑，由浏览器直接请求 `GET /chats/share/{share_id}` 取数；链接生成与页面路由分别见 `ShareChatModal.svelte:31` 和 `src/routes/s/[id]/+page.svelte`。
- 快照语义：该接口返回 shared_chat 快照行转换出的 ChatModel 视图。快照与源会话相互分离，源会话后续的修改不会自动反映，需要在分享弹窗里显式“更新链接”才会重新快照。分享时复制会话 JSON，附件文件不进入快照。快照视图的实现见 `backend/open_webui/models/chats.py:1519-1538`。
- 作者归属：只读查看他人会话时，聊天页按快照中的 user_id 加载原作者资料，并传给消息列表和 Overview，因此头像等归属信息跟随会话所有者，与当前查看者无关。实现见 `src/lib/components/chat/Chat.svelte:372-397,4086-4087`。
- 可见性分三档，前端编辑入口与后端的判定、过滤逻辑分别位于 `AccessControl.svelte:217-245` 和 `backend/open_webui/utils/access_control/__init__.py:220-289`：
  - private：没有任何 `*` 授权，只有显式指定的用户或用户组可读；
  - public：授予 `user:* read`，任一登录用户可读；
  - open：授予 `anyone:* read`，匿名访客可读。
  服务端按当前用户的权限过滤掉其无权授予的级别；会话所有者与管理员（开启 `ENABLE_ADMIN_CHAT_ACCESS` 时）始终可读，授权判定见 `access_grants.py:540-620` 与 `chats.py:81-103`。
- 撤销与管理：删除单个分享调用 `DELETE /chats/{id}/share`，会清掉快照行并回写会话字段与授权；全部撤销调用 `DELETE /chats/share/all`。列表管理入口在 Settings 的 Shared Chats 弹窗，支持分页、搜索以及逐条或全部取消。没有过期时间机制。两个删除端点见 `chats.py:1123-1148,1983-2005`，列表界面见 `SharedChatsModal.svelte`。
- 克隆：`POST /chats/{id}/clone/shared` 把快照（或 admin 下的任意会话）按原始会话 ID 与分支指针导入为访问者自己的会话，分享页提供 "Clone Chat" 按钮（`chats.py:1822-1889`、`s/[id]/+page.svelte:148-164`）。
- 事件：分享、撤销与导入分别发送 EVENTS 下的 CHAT_SHARED、CHAT_UNSHARED、CHAT_IMPORTED 三个事件，用于审计与通知（`chats.py:1952-1976`）。

## 9. 隐私、安全与内容治理

- 分享前流程没有敏感内容提示，也不对 system prompt 做过滤；快照复制的是完整会话 JSON，包含 system、params 与变量快照，随 chat 对象整体写入，没有单独的裁剪步骤。
- `/s` 页面声明了 `noindex,nofollow`，站点没有 /share 目录或搜索索引；全仓未找到分享列表的公开页面，`GET /chats/shared` 只返回当前用户自己的分享（`s/[id]/+page.svelte:173`、`chats.py:1151-1180`）。
- 公开分享与开放分享的权限开关默认关闭，对应 `ALLOW_PUBLIC_SHARING` 与 `ALLOW_OPEN_SHARING` 两个配置项（`config.py:1856-1862`）。
- 社区分享把完整的 chat 对象经 postMessage 交给第三方站点 openwebui.com，由对方页面处理，其存储、可见性与保留策略无法从本仓库确认；该功能由 `ENABLE_COMMUNITY_SHARING` 控制，默认开启（`config.py:2074`）。
- PDF/TXT 均为本地生成，无服务端富文本处理；样式 PDF 的 DOM 来源是已渲染的聊天内容（本应用渲染管线），未发现额外脚本注入面。

## 10. 性能、失败恢复与测试

- 样式 PDF 为单次全量 canvas（scale 2、宽 800px），长会话的高度与内存取决于 canvas 上限，代码无分段再拼或压缩中间态（除分页切条外）；异常路径只记控制台错误，且克隆节点清理与容器复位只写在成功路径（`Menu.svelte:186-191`）——若 html2canvas 抛错，离屏克隆节点可能残留 body。此为静态推断，未运行验证。
- 分享失败：`shareChatById` 失败时前端无 toast，仅控制台输出；Safari 分支用异步 ClipboardItem 写剪贴板（`ShareChatModal.svelte:187-213`）。
- 测试：本次未运行，也未搜索测试套件；PDF 分页、快照权限与匿名访问是否已有运行级测试证据处于未查证状态。

## 11. 设计取舍与已确认边界

- PDF 只有客户端一种生成位置，按样式与文本两种模式实现；后端不再提供服务端 PDF 端点，用户可见开关只控制这两种模式。
- 分享采用“快照 + 同 URL 覆盖”，与 `Chat.share_id` 单值绑定（一会话同时只有一个有效分享 token）；源会话变化不会实时进入分享，删除后重新分享会生成新 URL。
- 快照只拷贝 JSON，不拷贝文件，附件可见性不随分享授权传递，是分享页对无登录访客的实质边界。
- 导出粒度固定在"活动分支的整会话"，没有 NextChat 式的逐条选择器或选区工作流。
- 社区上传完全依赖第三方 openwebui.com，本地无发布对象、无回链管理。
- 内容口径差异：TXT/纯文本 PDF 保留原始 `content`（可能含 details 标记），样式 PDF 是渲染结果，JSON/快照是原始数据——三种口径并存且不统一。

## 12. 未验证事项

- PDF 实际渲染效果、分页观感、长会话/大图下 html2canvas-pro 的 Canvas 上限与内存表现；跨域图片无 CORS 头时的实际失败行为（需运行验证）。
- /s 链接的匿名与登录访问实际行为（open/public/private 三态端到端）、快照页附件与图片的实际加载（静态推断需登录）。
- 异常路径下离屏克隆节点是否残留 body（静态推断）。
- openwebui.com 社区上传的实际成功/失败表现与内容可见性（第三方站点）。
- 消息 `content` 中 reasoning `<details>` 标记在 TXT 导出中的实际落库形态与呈现（未运行会话样本）。
- 分享统计事件（CHAT_SHARED 等）是否接入审计/通知 UI（后端已确认发送，消费端未追踪）。
- "stylizedPdfExport" 设置从设置页保存到用户 settings 后的生效链路（代码路径存在，未运行确认）。

## 13. 关键源码索引

- `src/lib/components/layout/Navbar/Menu.svelte`（聊天页下载链：`downloadPdf`、`downloadTxt`、`downloadJSONExport`、`getChatAsText`）
- `src/lib/components/layout/Sidebar/ChatMenu.svelte`（侧边栏同款下载链）
- `src/lib/components/chat/ShareChatModal.svelte`（分享弹窗：建链/更新/删除/社区交接）
- `src/lib/components/workspace/common/AccessControl.svelte`（可见性三态与授权编辑）
- `src/lib/components/layout/SharedChatsModal.svelte`（共享列表管理）
- `src/routes/s/[id]/+page.svelte`（分享快照页）
- `backend/open_webui/routers/chats.py`（`/{id}/share`、`/share/{share_id}`、`/share/all`、`/shared`、`/shared/{id}/access`、`/{id}/clone/shared`、`/import`、`/all`、`/stats/export`）
- `backend/open_webui/models/shared_chats.py`（`SharedChats.create/update/get_by_id/delete_by_*`）
- `backend/open_webui/models/chats.py`（`get_chat_by_share_id` 快照视图、`ChatResponse`）
- `backend/open_webui/models/access_grants.py`（`has_anyone_access`、`has_access`）
- `backend/open_webui/utils/access_control/__init__.py`（`filter_allowed_access_grants`）
- `src/lib/components/layout/Sidebar/ChatMenu.svelte:91` 与 `src/lib/components/notes/utils.ts:61`（客户端 PDF 生成）
- `src/lib/apis/chats/index.ts`（`shareChatById`、`getChatByShareId`、`deleteSharedChatById`、`cloneSharedChatById`、`getSharedChatList`）
- `src/lib/components/chat/Messages/structuredOutput.ts`（`getOutputText`）、`src/lib/utils/index.ts`（`createMessagesList`、`removeAllDetails`）
- `src/lib/components/chat/Settings/DataControls.svelte`（全量导出/导入、Shared Chats 入口）、`src/lib/components/chat/Settings/SyncStatsModal.svelte`（社区统计同步）
