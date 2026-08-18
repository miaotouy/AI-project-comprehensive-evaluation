# SillyTavern 对话导出与分享调查笔记

> 调查对象：`https://github.com/SillyTavern/SillyTavern`
>
> 调查更新日期：2026-08-14
>
> 代码快照：`8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8`（分支：`release`）
>
> 调查方式：静态源码局部调查；读取过去聊天列表导出按钮与点击处理器、`/api/chats/export` 服务端实现（jsonl 直读与 txt 投影）、`/api/chats/import` 与 `/api/chats/group/import` 转换器、Assistant 聊天导出/导入、消息持久化 schema（swipes/swipe_info/branch/附件引用）、群聊消息结构；检索 html2canvas/jsPDF/window.print/navigator.share 等库与 API；未运行应用
>
> 调查范围：对话导出与分享能力（JSONL/TXT 导出、导入往返、角色与群聊信息、swipe/branch、附件口径、分享载体）；不覆盖角色卡 PNG/JSON 导出（归 Agent 角色类目）、自动聊天备份（归备份恢复类目）、SD 资产清单下载
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

SillyTavern 的对话导出是单一 `E1 数据交换` 类型：两条格式（JSONL 原样导出、TXT 正文导出）、一个入口面（“管理聊天文件”弹窗内每个聊天块的导出按钮）、一种交付方式（浏览器本地文件下载）。本次未找到分享稿编辑器、导出预览、PNG/HTML/PDF 交付、剪贴板分享或链接/远端发布。

- JSONL 导出是持久化原始数据的逐字节交付：服务端对聊天文件直接整读回传（`src/endpoints/chats.js:625-643`），header 行（`chat_metadata`）、系统消息、完整 swipe 历史、附件引用与分支字段原样保留。点击导出前客户端先强制落盘（`saveChatConditional`，`public/script.js:11443`），保证导出即磁盘最新状态。
- TXT 导出是可见正文投影：服务端 readline 流式处理，跳过 `is_system` 消息，输出 `name: (extra.display_text || mes)`（`chats.js:645-669`）。`extra.display_text` 仅由 translate 扩展写入（译文），因此译文优先；`mes` 与活动 swipe 互为镜像，故 TXT 只含活动 swipe，附件与元数据全部丢弃。
- 往返：JSONL 导出可无损导回——导入时校验首行结构后逐字节复制落盘，未知字段保留（Chub 聊天数据是唯一被改写的情况，会拍平其 `mes`/`swipes` 的对象包装）；TXT 无导入路径。导入另支持 Kobold Lite、CAI Tools、oobabooga、Agnai、RisuAI 五种外部 JSON 格式，投影为无 swipe 的简化消息。群聊导入仅接受自身 JSONL。
- 角色/群聊信息以消息级字段携带：每条消息的 name 字段（说话人）随 JSONL 原样保留，群聊消息另有 `original_avatar`/`force_avatar` 头像引用（`public/scripts/group-chats.js:594-608`）；群成员配置在独立 group 文件中，不进入聊天导出；角色卡/提示词快照不嵌入（角色资产交换属 Agent 角色类目）。
- swipe/branch：JSONL 原样导出保留同一消息的全部 swipe 与 `swipe_info`；分支以独立聊天文件 + header 父引用 + 分支点名单表达（`public/scripts/bookmarks.js:186-243`），导出按文件粒度进行，一次只导出一个文件、不打包分支树。swipe 选择器中的“导出”按钮被改造成“创建分支”操作（`public/scripts/swipe-picker.js:159-174`），不作为导出入口。
- 本次未找到：HTML/PDF/PNG 对话交付与长图生成（全仓检索 html2canvas、jsPDF、window.print 等库均无对话相关使用，toDataURL 仅用于视频缩略图与头像裁剪）、navigator.share 系统分享、Gist/公开链接/远端快照及对应访问控制。

## 系统边界与完整主链

```text
主链 A：管理聊天文件弹窗（角色聊天与群聊共用）
过去聊天列表块 .exportRawChatButton(jsonl) / .exportChatButton(txt)
  -> saveChatConditional() 先落盘当前会话
  -> POST /api/chats/export {is_group, avatar_url, file, exportfilename, format}
  -> 服务端按 format 分流：jsonl=原文件直读回传；txt=readline 投影(name + display_text/mes，跳过 is_system)
  -> 客户端 download(data.result, exportfilename) 本地下载
```

```text
主链 B：Assistant 临时聊天（客户端直出，无服务端参与）
assistantNote 模板 .assistant_note_export
  -> 内存 chat 过滤掉 ASSISTANT_NOTE 类型系统消息
  -> 每行 JSON.stringify 拼接 -> download() 生成 "<Assistant - 时间>.jsonl"
```

```text
导入链：管理聊天文件弹窗导入按钮 / 拖放文件
  -> POST /api/chats/import（json：外部格式转换 / jsonl：header 校验 + 原样写入）
     POST /api/chats/group/import（仅自身 jsonl，复制后登记进 group.chats）
  -> 落盘为 "<角色名> - <时间> imported.jsonl"，不覆盖源文件
```

## 1. 入口、用户目标与导出源

- 主入口：“管理聊天文件”弹窗（`#option_select_chat` 选择器经渲染函数链打开），每个聊天块渲染导出按钮（`public/index.html:6779-6780`、`public/script.js:8521-8558`）；按钮在键盘可聚焦序列中（`public/scripts/keyboard.js:25-26`）。本次未找到斜杠命令、消息级菜单或 Chat UI 中的其他导出入口。
- 导出源：磁盘上的单个完整聊天文件（`.jsonl`），不接受内存选区或可见消息子集；角色聊天与群聊共用同一模板与点击处理器，群聊请求带群聊标记（`is_group: true`）、头像地址为空（`script.js:11447-11453`），服务端按该标记选择 chats 或 groupChats 目录（`chats.js:608-614`）。
- 用户目标：JSONL 面向存档与跨应用/跨安装交换，TXT 面向阅读传播。无批量导出，一个按钮导出一个文件。
- 次要入口：Assistant 临时聊天的 “Export as JSONL / Import from JSONL”（`public/scripts/templates/assistantNote.html:5-12`、`public/scripts/chats.js:2138-2180`），导出当前内存会话（过滤 ASSISTANT_NOTE 系统消息），导入则解析文件后直接拼接进当前会话——它是独立于服务端管线的浏览器端往返。

## 2. 范围选择、内容口径与字段过滤

- 无范围/选区/单条消息选择能力：整文件导出，顺序即磁盘 JSONL 顺序。
- JSONL 口径 = 持久化原始数据：服务端直读原文件（`src/endpoints/chats.js:625-643`），无字段过滤、无转换、无脱敏，system 消息、`chat_metadata`、全部 `extra` 内部字段（token_count、api/model、gen_id 等）均随文件交付。
- TXT 口径 = 可见正文：跳过 `is_system` 消息（`chats.js:653-655`），按“说话人名: 文本”格式输出（`chats.js:656-660`）；`extra.display_text` 只由 translate 扩展写入（`public/scripts/extensions/translate/index.js:215`），因此译文存在时导出译文、否则导出原文。无标题、无日期、无模型/角色元信息。
- swipe 口径：持久化中当前文本与活动 swipe 互为镜像（`script.js:6837`、`6895`），故 TXT 只含活动 swipe；JSONL 含 `swipes` 全历史。
- Assistant 导出口径：内存 `chat` 减去 ASSISTANT_NOTE 类型系统消息（`chats.js:2147`），其余消息（含其他系统消息与 swipe）原样序列化。

## 3. 附件、资源与离线封装

- JSONL：附件以引用形式保留（消息 schema 的 `extra.media[].url`、`extra.files` 等字段，含已弃用的 image/video 变体，`public/global.d.ts:107-119`），二进制实体不打包；交付物在其他安装或机器上无法解析附件，不能离线打开。
- TXT：附件无任何表达。
- 无内联、无打包、无 base64 嵌入路径。

## 4. 格式、schema 与往返能力

- 格式与命名：jsonl（原文件直读）与 txt（投影正文）两种。导出文件名 `<聊天名>.jsonl` / `<聊天名>.txt`（`script.js:11451`）。下载 MIME 分别为 `application/octet-stream` 与 `text/plain`（`script.js:11469`）。
- schema：JSONL 首行为 `ChatHeader`（`chat_metadata` + 占位的人名/角色名字段，`script.js:7368-7373`），其后每行一条 `ChatMessage`（`global.d.ts:66-81`）。无显式格式版本号，兼容性靠字段存在性判定。
- 往返（JSONL）：导入校验首行含 `user_name`、`name`、`chat_metadata` 任一（`chats.js:764`）。非 Chub 数据时逐字节复制落盘、未知字段完整保留（`chats.js:786`）。Chub 聊天数据是唯一改写路径：其 `mes`/`swipes` 中的对象包装会被拍平成字符串（`chats.js:258-279`）。导入另存为新文件，不覆盖源（`chats.js:780-782`）。
- 往返（外部 JSON）：按结构特征识别五种外部格式并转换，全部投影为 `name/is_user/mes/send_date/extra` 简化消息（不保 swipe 与分支），CAI 支持多历史批量导入（`chats.js:718-738`、转换器 `110-308`）。识别特征对照如下：

| 格式 | 识别特征 |
|---|---|
| Kobold Lite | `savedsettings` |
| CAI Tools | `histories` |
| oobabooga | `data_visible` |
| Agnai | `messages` |
| RisuAI | `type==='risuChat'` |
- 往返（群聊）：客户端对群聊禁用 json 格式（`script.js:12032-12035`）；服务端将文件直接复制进 groupChats 目录，客户端把新会话 ID 登记进群成员表并保存群（`chats.js:676-694`、`group-chats.js:2318-2347`）。
- 角色/群聊信息如何携带：
  - 角色聊天：消息级 `name` 字段（角色名 / 用户 persona 名）随 JSONL 原样保留；TXT 以 `name:` 前缀区分说话人。
  - 群聊：消息 `name` = 角色名，`original_avatar`/`force_avatar` = 头像引用（`group-chats.js:594-608`）；群配置（成员列表、禁用成员、生成模式）在独立 group 文件中，不进入聊天导出；群聊 JSONL 导入只挂到当前群，不携带成员信息。
  - 角色卡/提示词不嵌入导出；`chat_metadata` 中的 scenario/persona/system_prompt 等会话级覆盖随 header 行在 JSONL 中原样保留。
- swipe/branch 保留：
  - JSONL 原样导出完整保留 `swipes`/`swipe_id`/`swipe_info`（含每条 swipe 的 send_date 与 extra）；
  - 分支是独立聊天文件（`bookmarks.js:186-243` 的 `createBranch`）。分支点消息记 `extra.branches` 名单，分支文件 header 记 `chat_metadata.main_chat` 父引用（`bookmarks.js:199,238-241`）；
  - 这些字段随 JSONL 原样导出，但导出按文件粒度进行，不打包分支树集合；TXT 只含活动 swipe、无分支概念；
  - swipe 选择器中导出按钮被改造为“创建分支”按钮（`swipe-picker.js:159-174`），不提供按 swipe 导出的功能。

## 5. 分享稿编辑、编排与预览 — 本次未找到

TXT/JSONL 导出无任何独立分享稿对象：无预览、无编辑、无内容开关、无选区编排或比较工作台，点击按钮后直接下载。搜索范围：`displayChats` 渲染、导出点击处理器及其依赖。

## 6. 图片、HTML、PDF 与富内容生成 — 本次未找到

应用代码（排除第三方 lib 目录）未引用 html2canvas、jsPDF、html2pdf，未使用 `window.print`；`toDataURL` 仅用于视频缩略图（`public/scripts/utils.js:1248-1277`）与头像裁剪（`public/scripts/popup.js:765`）。TXT 为纯文本，Markdown 等富内容以原始文本形式包含、不转换。无对话截图、无 PNG/HTML/PDF 交付物。

## 7. 生成历史、版本与持久化

- 无分享稿版本历史：每次点击都是对同一聊天文件的一次性投影下载，服务端不持久化导出产物，客户端无导出记录。
- 分支/检查点（`chat_metadata.main_chat`、`extra.branches`）是会话管理侧的版本语义，随 JSONL 原样导出保留，但由书签/分支功能维护，与导出功能无交互。
- 自动聊天备份（`src/endpoints/chats.js:41-78 backupChat`）属备份恢复类目，不记入本类目。

## 8. 分享载体、访问控制与撤销 — 不适用（本地文件交付）

交付物只有浏览器本地文件（`<a download>` + Blob，`public/scripts/utils.js:405-412`）。本次未找到 `navigator.share`/Web Share、远端快照、公开页面、Gist 或任何服务端分享对象；不存在 URL 可枚举、登录、撤销、过期、更新与克隆语义。Electron 包装层未找到 `will-download` 等下载拦截（`src/electron/index.js` 无相关处理），下载仍走浏览器机制——需运行验证。

## 9. 隐私、安全与内容治理

- TXT 导出过滤 `is_system` 消息，但用户消息、角色名、persona 名与译文全文原样输出；无密钥/路径扫描、无脱敏选项。
- JSONL 导出即全量原始数据，含 `chat_metadata`（可能含 scenario/persona/系统提示覆盖）与 `extra` 内部字段，属“原始数据即交付物”设计，无任何过滤提示。
- 服务端对导出文件名做 sanitize 与路径穿越校验（`chats.js:611-613`、`src/middleware/validateFileName.js`），读取限定在用户数据目录内；导出内容本身不解析、不渲染 HTML，无富文本脚本注入面。

## 10. 性能、失败恢复与测试

- JSONL 直读整文件；TXT 用 readline 流式逐行处理，避免整读大文件（`chats.js:645-669`）；客户端最终都整体放入 Blob 下载（`utils.js:405-412`），下载侧无分片。
- 错误路径：文件缺失返回 404 + message（`chats.js:616-622`）、读取失败 500（`chats.js:636-642`）、异常 400；客户端对非 ok 响应与 fetch 异常均 toastr 报错（`script.js:11462-11481`），成功路径先 toastr 再触发下载。
- 导出前 `saveChatConditional` 等待在途保存结束并取消防抖保存（`script.js:9352-9362`），避免导出过期状态。
- 本次未找到针对导出/导入的自动化测试；下载触发、导入解析等浏览器/交互行为需运行验证。

## 11. 设计取舍与已确认边界

- 双格式一条管线：同一 `/api/chats/export` 按 `format` 分流，jsonl 交付原始数据（交换/迁移）、txt 交付可见正文（阅读），两种口径刻意不同，且 txt 的“可见正文”含译文替换语义。
- 导出被定义为聊天文件管理面操作（文件级、无选区、无预览），没有会话内容工作台；与 NextChat 的逐条选择 + 品牌图片稿形成明显不同路线。
- 往返以 JSONL 为唯一无损通道（逐字节复制、未知字段保留）；外部格式导入只保文本与角色归属。
- 分支关系由文件命名体系 + `chat_metadata`/`extra` 字段表达，而非单文件内嵌树结构；附件以引用而非打包表达，交付物自包含性低。
- 边界确认：角色卡 PNG/JSON 导出（入口 `#export_button`，`script.js:11970-12008`）属 Agent 角色类目。SD 资产清单下载（`extensions/assets` 的 `downloadAssetsList`，`index.js:289-313`）是资产列表而非对话导出。自动备份属备份恢复类目。以上均不作为对话导出主体记录。

## 12. 未验证事项

- 浏览器实际下载行为、超长会话 TXT/JSONL 下载的内存与性能表现（服务端流式 vs 客户端整体 Blob）。
- 群聊导出的实际可用性（静态路径推断可用：`is_group=true` 时 `avatar_url` 可缺省、目录切换到 groupChats，但未运行确认）。
- Chub 数据 flatten 对真实文件的改写程度及失败兜底路径。
- 导入成功后客户端 `displayPastChats` 刷新与高亮表现；多文件导入顺序。
- 存在 `extra.display_text`（译文）时 TXT 导出口径切换的实际运行结果。
- Electron 窗口内下载对话框与浏览器路径的差异（源码未找到拦截逻辑）。
- 本次未运行应用，所有入口点击、Toast、下载、导入解析行为均为静态代码确认。

## 13. 关键源码索引

- `public/script.js`（导出点击处理器 `:11440`；`displayChats` 渲染导出按钮 `:8521`；`saveChatConditional` `:9352`；导入文件选择 `:12014`；`saveChat` header 结构 `:7336`）
- `public/index.html`（导出按钮 `:6779-6780`；导入表单 `:6662-6678`）
- `public/scripts/utils.js`（`download` `:405`）
- `src/endpoints/chats.js`（`/export` `:604`；jsonl 直读 `:625`；txt 投影 `:645`；`/import` `:696`；`/group/import` `:676`；`flattenChubChat` `:258`；外部格式转换器 `:110-308`；`backupChat` `:41`）
- `public/scripts/chats.js`（Assistant 导出/导入 `:2138-2180`）
- `public/scripts/templates/assistantNote.html`
- `public/scripts/bookmarks.js`（`createBranch` 分支文件语义 `:186-243`）
- `public/scripts/group-chats.js`（群聊消息结构 `:594-608`；`importGroupChat` `:2318`）
- `public/global.d.ts`（消息/header/附件 schema `:50-128`）
- `public/scripts/swipe-picker.js`（导出按钮改造为分支按钮 `:159-174`）
- `src/server-startup.js`（`/exportchat` 兼容重定向 `:100`；路由挂载 `:161`）
