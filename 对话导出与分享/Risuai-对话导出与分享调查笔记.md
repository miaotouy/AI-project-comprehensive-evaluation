# Risuai 对话导出与分享调查笔记

> 调查对象：`E:\works\GitStudyNotes\Risuai`
>
> 调查更新日期：2026-08-17
>
> 代码快照：`0551d283faeba6e73899b01dd85ea38307b24699`（分支：`main`）
>
> 调查方式：静态源码局部调查；阅读 `src/ts/characters.ts` 的单会话导出/导入/批量导出、`src/lib/ChatScreens/DefaultChatScreen.svelte` 的聊天截图与菜单入口、`SideChatList`/`ChatList` 两处聊天列表入口、`src/ts/storage/exportAsDataset.ts` 数据集导出、`src/ts/sync/multiuser.ts` 多用户房间、`parser.svelte.ts` 的 `parseMarkdownSafe` 与 `ParseMarkdown` 双管线、`database.svelte.ts` 的会话与消息 schema、下载与文件选择工具；检索 navigator.share、html-to-image、jsPDF 等库的实际使用面；未运行应用
>
> 调查范围：对话与消息层面的导出、导入往返与分享（JSON/TXT/HTML 文件、HTML 剪贴板、PNG 截图、数据集导出、多用户房间实时分享）；不覆盖角色卡导入导出与 Risu Hub 角色分享（Agent 角色类目）、本地备份与 Google Drive 云备份（备份恢复类目）、多用户房间的输入与生成工作流细节
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Risuai 的对话导出与分享是"本地交付为主、一条实时房间旁路"的布局。同一个单会话导出弹窗分化出四种模式，另有批量导出、数据集导出和聊天截图三条独立管线，导出源统一是内存中整份会话对象，但各模式的内容口径差别很大。

- 单会话导出（`exportChat`，`characters.ts:192-369`）四选一：JSON 为持久化原始数据整包（`risuChat` v2，含全部内部字段与所属文件夹）；TXT 为可见正文投影；HTML 文件为渲染正文加隐藏 `.idat` 节点内嵌原始 JSON 的双轨交付；HTML 剪贴板为表格复制。后两种 HTML 模式可选翻译与角色名匿名化。
- 角色级批量导出（`exportAllChats`，`characters.ts:507-526`）与全局数据集导出（`exportAsDataset.ts`，用户设置页入口）把会话按 JSON 交付，数据集版跳过群聊并只保留角色名、描述、消息与世界书四个字段。
- 聊天截图（`DefaultChatScreen.svelte:449-503`）先全量挂载消息，再用 html-to-image 逐条消息截取现场 DOM、纵向合并为单张 Canvas 后下载 PNG，是唯一图片交付；无预览、无尺寸或水印配置。
- 往返能力分层：JSON（v1/v2）与 HTML 文件（.idat）可回导；JSONL 只有 Tavern 导入方向；TXT 无导入路径，且文件选择框允许选 txt 但代码无对应分支。会话导出不自带开场白，开场白来自角色卡。
- 多用户房间（`multiuser.ts`）是 peerjs 的 WebRTC 实时分享：房间码即主机 peer ID，访客经 Playground 输入房间码加入，主机下发当前角色与当前会话；无鉴权、无口令、无持久化、断线即结束，与文件导出形成"快照 vs 实时"两种极端。
- 富内容保真偏低：HTML 导出走简化的 `parseMarkdownSafe` 管线，资产标记、Thoughts、工具调用保持字面文本，代码高亮与链接被禁用，明显弱于现场渲染。

## 系统边界与完整主链

```text
主链 A：单会话导出（聊天列表行内下载按钮 -> exportChat）
  alertSelect 四模式
    JSON：chat 整对象 + 所属文件夹 -> <角色名>_<日期>_chat.json
    TXT：逐条 "--名字\n原始文本"（非群聊前置开场白）-> .txt
    HTML 文件：逐条 parseMarkdownSafe（可选翻译/匿名化）+ 开场白
             + .idat 内嵌转义原始 JSON -> .html
    HTML 剪贴板：表格模板 -> ClipboardItem(text/html + text/plain)
```

```text
主链 B：聊天截图（聊天屏幕菜单 "Screenshot"）
  loadPages = Infinity 触发全量挂载
  -> html-to-image 逐条 .risu-chat 元素 toCanvas
  -> Canvas 纵向拼接（主题背景色填充）
  -> downloadFile chat-<uuid>.png
```

```text
主链 C：多用户房间（实时分享）
  主机：聊天列表菜单 "Create Multiuser Room" -> peerjs Peer(UUID-rmh)
  访客：Playground "Join Multiuser Room" 输入房间码
  -> 主机下发当前角色（仅当前会话）与资产图片
  -> 生成前后 peerSafeCheck 互斥、peerSync 广播会话
  -> 断线/关闭即结束
```

## 1. 入口、用户目标与导出源

- 入口面共四处，都是图标按钮或设置项，无消息级菜单、斜杠命令、命令行或外部 API 入口：
  - 会话列表（`SideChatList.svelte`）：行内下载按钮 `:313-322`、`:425-434`；列表底部批量导出与导入按钮 `:466-475`；
  - 会话列表弹窗（`ChatList.svelte`）：行内下载 `:41-48`、导入 `:93-97`；
  - 聊天屏幕菜单：截图项 `DefaultChatScreen.svelte:995-1000`；
  - 用户设置页：数据集导出按钮 `UserSettings.svelte:133-134`。
- 导出源：`DBState` 内存中的单个 `Chat` 对象（`characters.ts:200-201`），整份导出，无选区、无单消息、无按分支筛选；分支本身就是独立会话文件（`Chat.svelte:845-859` 复制当前会话、截断到分支点并追加 `{{specialcomment::branchedfrom::}}` 注释消息），导出按会话粒度进行。会话内全部消息（含禁用消息、注释消息）一律进入导出。
- 用户目标分层：JSON 与批量 JSON 面向存档与跨安装迁移；TXT/HTML/PNG 面向阅读传播；数据集导出面向训练用途；多用户房间面向与他人共同游玩同一个角色与会话。

## 2. 范围选择、内容口径与字段过滤

- 无任何范围选择能力：整会话导出，顺序即 `chat.message` 数组顺序（末尾为最新）；开场白不在会话内（在角色卡的 `firstMessage`/`alternateGreetings`），四种模式各自另行拼接。
- JSON 口径 = 持久化原始数据：`{type:'risuChat', ver:2, data:chat, folders}`，chat 原样携带消息及其生成信息/提示词信息、note、localLore、记忆数据、绑定人设、书签等内部字段；`folders` 仅在会话挂在文件夹下时包含该文件夹。无脱敏、无字段过滤。
- TXT 口径 = 可见正文投影：逐条输出 `--说话人名\n原始文本`，群聊消息取 `saying` 指向角色的名字，其余按角色名/用户名；非群聊前置开场白（`characters.ts:349-361`）。不做 Markdown 渲染，`{{image::}}` 等特殊标记原样输出。
- HTML 文件口径 = 渲染正文与原始 JSON 双轨：正文经 `parseMarkdownSafe` 渲染（markdown-it + DOMPurify 白名单），逐条可选翻译（`translateHTML`）与角色名匿名化（正文中角色名大小写不敏感替换为 `×××`，但消息标题与开场白标题仍显示真名）；页面底部 `.idat` 隐藏节点内嵌转义后的 chat 原始 JSON 供回导（`:297-299`）。
- HTML 剪贴板口径 = 仅表格正文，不含 .idat，不可回导；第一行固定用 `char.firstMessage`（`:328`），与 HTML 文件模式按 `fmIndex` 选开场白（`:291-293`）不一致。
- 截图口径 = 现场渲染结果：当前主题、当前 DOM 中已挂载消息的所见状态。

## 3. 附件、资源与离线封装

- 消息内图片与文件以标记文本存储：`{{image::资产名}}`、`{{file::文件名::base64内容}}`、`{{inlay::id}}` 等（`cbs.ts:971-981`、`:2332-2337`）。JSON 与 TXT 导出原样交付这些标记，二进制实体不打包，交付物在无资产环境下不可解析。
- HTML 导出管线不含资产解析：导出只调用 `parseMarkdownSafe`，不经过现场渲染的资产与内联标记解析（`parser.svelte.ts:482-701`），标记保持字面文本；markdown 图片语法产生的 img 保留外链 URL，不内联。HTML 文件离线打开时资源留空。
- PNG 截图依赖浏览器对现场 DOM 的加载结果：本地资产若已显示可进入画布；跨域资源与 Tauri 资产协议 URL 能否被 html-to-image 内联未见处理代码，需运行验证。

## 4. 格式、schema 与往返能力

- 输出格式共五类，其中 jsonl 只有导入方向：

| 格式 | 形态 | 角色 |
|---|---|---|
| json | `risuChat` v2（单会话）、`risuAllChats` v2（批量） | 导出 + 回导 |
| txt | 正文投影 | 仅导出 |
| html | 正文 + `.idat` 内嵌原始 JSON | 导出 + 回导 |
| png | 截图 | 仅导出 |
| jsonl | Tavern 消息行 | 仅导入 |

文件名为 `<角色名>_<日期>_chat` 加扩展名，非法文件名字符被替换（`characters.ts:232` 等）。
- 往返（JSON）：导入按 `type` 与 `ver` 字段识别两个 v2 变体及各自的 v1 形态（`characters.ts:420-489`）。v2 单会话与批量共用分支：`folderId` 与现有文件夹冲突时生成新 id 并重映射，会话一律换新 id 后插入列表头部；v1 只补缺省字段。导入不自带开场白，开场白取自当前角色卡。
- 往返（HTML）：取 `.idat` 节点的 `textContent`（HTML 实体自动还原）解析 JSON，校验 `message`/`note`/`name`/`localLore` 存在后直接 `unshift`，不更换 id（`:490-501`），与 JSON 导入的重生成 id 行为不一致。
- 往返（JSONL Tavern）：逐行解析 `name`/`is_user`/`mes`，首行视为头跳过；`{{user}}`/`{{char}}` 占位符按当前用户名与角色名替换（`formatTavernChat`，`:528-531`）。第 394 行的条件实为逗号表达式，等效只检查 `mes` 是否存在。
- TXT 无导入：文件选择框允许 `txt` 扩展名（`:372`），但 jsonl/json/html 三个分支之外无处理，选择 txt 会静默返回。
- 未知字段策略：JSON 往返除 id/folderId 重映射外原样保留未知字段；无格式版本号之外的 schema 校验。

## 5. 分享稿编辑、编排与预览 — 本次未找到

HTML 模式的翻译与匿名化是导出参数（导出前弹窗确认）而非独立编辑表面；无预览、无选区编排、无内容开关工作台，点击后直接生成交付物。截图无预览、无水印、尺寸、倍率或主题设置，直接下载。搜索范围：`exportChat` 全流程、`DefaultChatScreen` 截图流程及其菜单。

## 6. 图片、HTML、PDF 与富内容生成

- PNG 是唯一图片交付。`screenShot` 先把分页上限置为 Infinity 触发全量挂载，再对每个消息根元素（选择器 `.default-chat-screen .risu-chat`，即 `Chat.svelte:1062` 的消息壳）调用 html-to-image 的 `toCanvas`，按消息顺序纵向合并为单张 Canvas 并以主题背景色填充空隙，最后转 PNG 下载（`DefaultChatScreen.svelte:449-503`）。无分段、无 DPR 或尺寸治理、无 Canvas 上限处理，长会话可能超过平台单画布限制。
- HTML 富内容保真按内容类型对照如下，整体弱于现场渲染管线：

| 内容 | 导出端表示 |
|---|---|
| Markdown、KaTeX 数学 | `parseMarkdownSafe` 渲染（`parser.svelte.ts:890-897`） |
| 代码块 | 渲染被整体禁用（`md.disable(['code'])`，`:43`），无语法高亮 |
| 链接 | `<a>` 标签被 DOMPurify 禁止，保留文字 |
| 内联样式与 class | 属性被剥离 |
| Thoughts、工具调用 | 字面文本 |
| 图片/文件/内联资产标记 | 字面文本（见第 3 节） |
| iframe | 仅放行 YouTube embed（`:46-52`） |
- PDF：本次未找到（无 jsPDF 类依赖、无打印导出路径；动态工具中的 `process/dynamicutils/pdf.ts` 是图片转 PDF 的模型输出工具，与对话导出无关）。

## 7. 生成历史、版本与持久化

- 无分享稿版本历史：每次导出独立生成新文件，无覆盖、无记录、无跨会话持久化的导出产物。分支与书签是会话管理侧的版本对象（分支会话带 `branchedfrom` 注释消息），随 JSON 原样导出保留，但导出功能本身不维护版本集合。

## 8. 分享载体、访问控制与撤销

- 本地交付：web 端走 `<a download>` 加 Blob，Tauri 端直写下载目录（`globalApi.svelte.ts:67-97`）；HTML 剪贴板模式通过 `ClipboardItem` 写入系统剪贴板（`characters.ts:337-341`）。均为一次性交付，无访问控制与撤销语义。本次未找到 `navigator.share`/Web Share。
- 多用户房间（实时分享）的接入链：创建入口在会话列表菜单（标注实验性，`SideChatList.svelte:296-300`），主机以 `v4() + "-rmh"` 生成 peer ID 作为房间码，侧栏展示供传播（`Sidebar.svelte:940-943`）；访客在 Playground 输入房间码加入（`PlaygroundMenu.svelte:128`）。
- 多用户房间的内容下发与同步：主机下发当前角色（仅当前会话）与资产图片，访客以 `chaId` 为 `§temp` 的临时角色接收（`multiuser.ts:288-313`）；生成前经 `peerSafeCheck` 互斥、失败则回滚，生成后 `peerSync` 广播会话（`process/index.svelte.ts:238-249`、`:1963`）。
- 多用户房间的安全边界：房间码即全部凭证，无口令、无鉴权、无过期；连接与数据通道默认不加密（peerjs 调用未传加密配置）；断线或关闭即结束，无服务端对象。

## 9. 隐私、安全与内容治理

- JSON、批量 JSON 与数据集导出是"原始数据即交付物"：含消息级生成信息与提示词信息（可能暴露 prompt 文本）、`bindedPersona`、记忆与书签数据；无密钥扫描、无路径检查、无脱敏选项。数据集导出同样无过滤。
- HTML 模式是唯一带内容开关的路径：可选"隐藏角色名"（正文替换为 ×××，消息标题与开场白标题仍显示真名，用户名不替换）与按当前翻译器翻译整段 HTML。TXT/JSON 无任何过滤。
- 导出端安全收敛面（HTML 经 DOMPurify 白名单处理）：
  - 禁 `a`、`style` 标签与 `style`、`href`、`class` 属性；
  - iframe 仅放行 YouTube embed；
  - href 仅接受 http/https。
  TXT 纯文本无注入面。
- 多用户房间的隐私面：访客接入即获得角色卡、当前会话全文与资产图片，无内容过滤或确认步骤；房间码可猜测性依赖 UUID，但无其他门禁。

## 10. 性能、失败恢复与测试

- 导出全程在内存完成：JSON 整对象序列化、HTML 逐条渲染后拼单页、TXT 逐条拼接，最终整体交给下载，无分片；Tauri 端单文件直写下载目录。
- 截图是全链路最重的操作：全量挂载（长会话 DOM 压力）+ 逐消息 Canvas + 单画布合并，无尺寸上限与内存治理；`loadPages` 的恢复语句在成功路径（`:498`），异常路径只 `alertError`（`:500-501`），静态推断失败后分页状态可能停留在 Infinity，需运行验证。
- 导入失败路径：空数据或未知 type 报"无数据"错误，解析异常整体 catch 报错；成功路径把新会话 `unshift` 并 `changeChatTo(0)`。
- 测试面：仓内仅有解析器单测（`src/ts/parser/tests/`），无导出/导入或截图测试；`AGENTS.md` 声明项目无综合测试套件。

## 11. 设计取舍与已确认边界

- 一个导出按钮四套口径刻意并存：JSON 交付原始数据（迁移），TXT 交付正文（阅读），HTML 文件用"可读正文 + .idat 可回导"解决传播与往返兼得，剪贴板表格面向即时粘贴。HTML 模式独有的翻译与匿名化表明该路径面向分享场景。
- 会话导出不自包含：开场白、角色资产、记忆的资产侧都留在角色对象上，跨端搬迁依赖角色卡导出（Agent 角色类目），会话 JSON 只承担会话本体。
- 截图复用现场 DOM 而非独立渲染器，走"所见即所得"路线，代价是导出受主题、挂载状态与浏览器资源加载影响；与提供分享稿工作台的项目形成明显不同路线。
- 边界确认：角色卡导入导出与 Risu Hub 分享（`characterCards.ts`）归 Agent 角色类目；`drive/backuplocal.ts` 的 .risudat 整库备份与 Google Drive 备份（`drive/drive.ts`）归备份恢复类目；多用户房间的输入、生成与界面交互归 Chat UI 与对话请求类目，本笔记只记录其分享语义；`process/dynamicutils/pdf.ts` 为模型输出工具，不在本类目。

## 12. 未验证事项

- 截图：长会话/高 DPR 下 Canvas 尺寸上限与内存表现、异常后 `loadPages` 是否停留在 Infinity、本地与跨域图片进入画布的行为、html-to-image 对 lazy 图片的捕获。
- HTML 翻译与匿名化的实际运行结果（LLM 翻译器对整段 HTML 的改写幅度）；剪贴板在 Tauri WebView 与 Web 平台上的权限表现。
- JSONL Tavern 导入对真实文件的逐行解析与占位符替换；HTML .idat 回导的实体还原与 id 复用影响；JSON 往返的未知字段保留。
- 多用户房间的连接建立、生成互斥、断线恢复与重连行为；数据通道无加密（peerjs 默认）与公共信令服务器的实际表现。
- 本次为静态调查，未运行应用；所有按钮点击、下载、剪贴板与截图行为均为静态代码确认。

## 13. 关键源码索引

- `src/ts/characters.ts`（`exportChat` 192-369、`importChat` 371-505、`exportAllChats` 507-526、`formatTavernChat` 528-531）
- `src/lib/SideBars/SideChatList.svelte`（行内导出 313-322、425-434；批量导出/导入 466-475；多用户房间入口 296-300）
- `src/lib/Others/ChatList.svelte`（导出 41-48、导入 93-97）
- `src/lib/ChatScreens/DefaultChatScreen.svelte`（`screenShot` 449-503、菜单入口 995-1000）
- `src/lib/ChatScreens/Chat.svelte`（分支创建 830-865、消息根元素 `.risu-chat` 1062）
- `src/ts/storage/exportAsDataset.ts`（数据集导出 6-28）
- `src/lib/Setting/Pages/UserSettings.svelte`（数据集导出按钮 133-134）
- `src/ts/sync/multiuser.ts`（`createMultiuserRoom` 60-256、`joinMultiuserRoom` 262-366、`peerSync` 369-391、`peerSafeCheck` 393-429）
- `src/ts/process/index.svelte.ts`（生成前后房间同步 238-249、1963）
- `src/ts/parser/parser.svelte.ts`（`parseMarkdownSafe` 890-897、`renderMarkdown` 152-204、`ParseMarkdown` 736-790、DOMPurify 钩子 46-110、`parseAdditionalAssets` 482-597）
- `src/ts/cbs.ts`（`file` 标记 971-981、`image` 等标记 2332-2379）
- `src/ts/storage/database.svelte.ts`（`Chat` 1817-1839、`Message` 1848-1860、`groupChat` 1510-1580）
- `src/ts/globalApi.svelte.ts`（`downloadFile` 67-97）
- `src/ts/util.ts`（`selectSingleFile` 49-69）
- `src/ts/drive/backuplocal.ts`、`src/ts/drive/drive.ts`（整库备份边界）
- `src/ts/characterCards.ts`（角色卡导入导出边界）
