# Pi 对话导出与分享调查笔记

> 调查对象：`https://github.com/earendil-works/pi`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`ff33ef42c4bd762cecd6958e3aabbc8e684ceb05`（分支：`main`）
>
> 调查方式：静态源码调查；读取 TUI 的 `/export`、`/import`、`/share`、`/copy` 处理链，`export-html` 模板（index/template.html/template.js/template.css/ansi-to-html/tool-renderer），SessionManager 树模型与 JSONL 读写，CLI `--export`、RPC `export_html`，`.pi/extensions/import-repro.ts`，`.github/workflows/issue-analysis.yml`，README 与 docs；未运行应用、浏览器、GitHub CLI 或 Hugging Face 操作
>
> 调查范围：HTML/JSONL 导出的导出源与分支语义、HTML 自包含性、Gist 分享内容与访问语义、HF 数据集发布的仓库边界与提示、各入口与导出源范围；不覆盖会话管理 CRUD、压缩/分支摘要机制本体和 pi.dev/session 查看器服务端实现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 的对话导出与分享围绕“会话即 JSONL 树”这一事实源展开，能力分属 `E1 数据交换`、`E4 链接分享` 和 `E5 发布与研究`（交接侧）：

- **JSONL 导出把当前分支线性化**：`getBranch()` 取出叶子到根路径上的条目，父指针重排成一条单链后写盘，侧枝与完整树因此不进入该文件。HTML 导出则把完整树（全部条目加 `leafId`）嵌进页面，默认按当前分支渲染，查看器侧栏可以浏览并切换到任意分支，两种导出口径由此不同。
- **HTML 是单文件自包含交付物**：样式表、应用脚本以及 marked 与 highlight 两个渲染库全部内联进模板（`export-html/index.ts:143-175`），会话数据以 base64 JSON 嵌在 session-data 脚本块中，图片内容块用 data: URL 渲染。页面不依赖外部 CSS、脚本或字体，可离线打开（推断，未运行验证）；Markdown 里引用远端图片的 URL 保持原样，离线时这类图片不显示。
- **`/share` 分 Radius 与 Gist 两条载荷不同的路径**：Radius provider 与凭据可用时，上传当前分支的 JSONL 并追加 system prompt 和工具 schema；否则导出自包含 HTML，交给 `gh gist create --public=false` 建成 secret Gist。客户端只负责创建链接，本地不保留更新、撤销、删除或过期记录。
- **HF 数据集发布位于仓库外**：本仓库承担“交付物与格式 + 引导”的角色，README 指引用外部伴生工具 `badlogic/pi-share-hf` 把会话发布成 HF 数据集，示例为 `badlogicgames/pi-mono`。数据来源、提示与权限默认值都由该外部工具负责；本次未找到仓库内的 HF 上传代码或隐私提示。
- 同仓库 CI（`issue-analysis.yml`）复用同一条导出链路：分析会话导出成 HTML 与 JSONL 后经 GitHub API 建 secret Gist（public 为 false），再把链接和 `/ir` 导入指令评论到 issue 上。`.pi/extensions/import-repro.ts` 演示了反方向的消费路径：匿名 `GET api.github.com/gists/{id}` 拉回 HTML 或 JSONL 并转回会话，构成一次完整往返。

## 系统边界与完整主链

```text
事实源：SessionManager 的 JSONL 会话文件（header + entries，id/parentId 树，append-only，leafId 指针）
  ├─ /export [路径]                -> .jsonl 分支线性化（重排 parentId）| .html 完整树 + leafId
  ├─ /export [路径.html]（TUI）     -> exportSessionToHtml（含 systemPrompt/tools/自定义工具 HTML）
  ├─ CLI pi --export in.jsonl [out.html] -> exportFromFile（无 AgentState，不含 systemPrompt/tools）
  ├─ RPC export_html               -> 同上 exportToHtml，供远端客户端（如 pi-chat）调用
  ├─ /share                        -> Radius: 当前分支 JSONL + 环境元数据；否则 HTML -> secret Gist
  ├─ /import <path.jsonl>          -> 复制进会话目录并 SessionManager.open 续跑（往返）
  └─ /copy                         -> 最后一条助手文本进剪贴板（简单交付，无选区工作流）
```

分享查看器主链（HTML 内部）：

```text
session-data（base64 JSON：header + entries + leafId + systemPrompt + tools + renderedTools）
  -> template.js 解析 -> 消息视图 = getPath(leafId) 当前分支；侧栏树 = 完整树可导航
  -> URL 参数 ?leafId=&targetId= 深链；每条消息有“复制本消息链接”按钮
  -> 按钮：下载 JSONL（完整树）、切换 thinking/工具输出展开
```

## 1. 入口、用户目标与导出源

内置斜杠命令列表定义于 `packages/coding-agent/src/core/slash-commands.ts:19-42`，入口在 `interactive-mode.ts:2895-2914` 分发：

- `/export [file]`：导出入口按目标文件后缀分流，写 .jsonl 时导出当前分支，其余路径一律产出 HTML。省略参数时自动命名：HTML 默认存为 `pi-session-<会话文件名>.html`（`export-html/index.ts:274-278`），JSONL 则带时间戳（`agent-session.ts:3250-3253`）。用途是个人存档与人际传播。
- `/import <path.jsonl>`：用户确认后把文件复制进会话目录并切换运行时接手，用于跨机恢复与接续（`agent-session-runtime.ts:361-396`）。
- `/share`：有可用的 Radius provider 与凭据时，把当前分支和环境元数据发布成组织可见的 artifact；没有可用凭据时改为创建 secret Gist，并返回查看链接（`modes/interactive/session-share.ts:24-203`）。
- `/copy`：把最后一条助手消息的文本放进系统剪贴板，复制范围固定在这条消息，没有选区或格式选项（`interactive-mode.ts:5956-5972`、`agent-session.ts:3291-3306`）。
- CLI 的 `--export <in> [out]`：非交互模式下把任意会话文件转成 HTML 后退出，适合脚本调用（`main.ts:626-638`；`args.ts:149-150, 288, 356-357`）。
- RPC 的 `export_html`：把导出能力提供给外部进程与客户端（`rpc-types.ts:59`、`rpc-mode.ts:596-598`）。

导出源粒度：只有“整会话”一个粒度。未发现单消息、连续范围、选区或批量会话导出入口；`/fork`/`/clone` 创建新会话属于会话管理，不在导出侧。顺序由树结构决定（见下节）。

## 2. 范围选择、内容口径与字段过滤

**JSONL 导出 = 当前分支线性化**（`agent-session.ts:3249-3280`）：

- 头行：`{type:"session", version:CURRENT_SESSION_VERSION(3), id, timestamp, cwd}`（不带 `parentSession`）。
- 条目：`getBranch()`（`session-manager.ts:1260-1270`，从 leafId 沿 parentId 走到根）取当前分支路径，注释明确“Re-chain parentIds to form a linear sequence”——每条重写父指针为前一条的 id。侧枝、分支摘要节点等路径外条目全部丢弃；导入后是线性会话。
- 路径上所有条目类型都保留（message、compaction、model_change、thinking_level_change、label、custom_message、branch_summary 等），不做字段裁剪。

**HTML 导出 = 完整树嵌入 + 分支视图**：

- `sessionData` 是嵌入页面的完整快照：头部、全部条目（含侧枝与隐藏消息）与 `leafId`，TUI 路径还会附带 system prompt、工具定义和预渲染工具 HTML（`export-html/index.ts:263-270`）。
- 查看器读入快照后分两处渲染：消息视图只取当前分支，侧栏树展示完整树；点击树节点会跳到该节点下最新的叶子（`template.js:73-176, 133-145, 1495-1551`）。
- 内容口径即持久化原始数据，thinking、工具调用与结果、bash 命令及输出、文件路径、图片 base64 都原样保留，没有请求 Payload 转换，也没有脱敏副本。
- 树与消息的显隐交给查看器端过滤，只作用于查看时的呈现，导出文件本身始终含全部条目：默认模式隐藏设置类条目（标签、自定义消息、模型与思考级别的变更记录），另可切换下列预设并配合搜索（`template.js:368-424`，模板按钮在 `template.html:20-27`）：
  - `no-tools`
  - `user-only`
  - `labeled-only`
  - `all`
- 隐藏消息按条目类型分别呈现：工具结果内联进对应的助手工具调用块，消息视图不单独渲染；thinking 块默认展开、可折叠；自定义消息只在 display 为 true 时渲染（`template.js:904-1063, 1249-1254, 1287, 1309-1314, 1792-1800`）。

## 3. 附件、资源与离线封装

- HTML 的内联装配在生成阶段完成：模板 CSS、模板 JS 以及 marked、highlight 两个渲染库被整体读入，替换进 `template.html` 的占位符（`export-html/index.ts:143-175`）；模板本身不引用任何外部脚本、样式、导入或 URL，字体只用系统字体栈（`template.css:19`）。
- 会话里的图片内容块不走外链，`ImageContent` 的 base64 数据直接写成 `data:<mimeType>;base64,<data>` 内联进页面，离线可见（`template.js:924, 1208, 1230`）。
- Markdown 正文引用的图片 URL 经 `sanitizeMarkdownUrl` 处理后原样输出为 img 的 src，保持远端引用，离线打开时这类图片仍需联网（`template.js:616-626, 1599-1610`）。
- 结论：HTML 交付物基本单文件自包含，可复制为单个文件离线打开（静态推断，未运行验证）；“本地文件双击打开”下深链与剪贴板 API 的部分行为依赖浏览器能力。

## 4. 格式、schema 与往返能力

- 导出格式只有 JSONL（v3，完整字段文档在 `docs/session-format.md`）与 HTML（v3 数据以 base64 JSON 内嵌）两种。本次搜索 `pdf|toPng|print` 只命中与导出无关的终端图片转换和 CLI print 模式，未发现 Markdown、PDF、PNG 导出、剪贴板图片导出或打印链路。
- JSONL 没有独立的导出 schema 版本，头行带 `version: 3`，条目按持久化格式原样写出。导入端由 `loadEntriesFromFile` 读取，要求首行的 type 为 session 且带 id，坏行会被跳过，打开会话后把最后一条设为 leaf（`session-manager.ts:514-556`）。所以 `/export x.jsonl` 的产物可以直接导回，但分支关系已被线性化，侧枝无法还原，未知字段原样保留。
- HTML 查看器的“下载 JSONL”按钮重建头部与全部条目，保留完整树、不重排 parentId（`template.js:1069-1090`）。这份文件的首行是 type 为 header 的记录，按导入端校验会被判为“not a valid pi session”（静态推断，未运行验证）；`.pi/extensions/import-repro.ts:96-118` 从 HTML 反向提取时写回的是 type 为 session 的头，可以导入。两处 JSONL 重建口径不一致。
- `docs/session-format.md` 与代码一致地声明 v3 = 树结构（`session-manager.ts:30`）。

## 5. 分享稿编辑、编排与预览

本次未找到独立于聊天现场的“分享稿编辑器”。HTML 导出即交付物：无选区编辑、内容开关（导出前）、主题之外无布局/品牌配置，唯一的导出期变量是 `themeName`（`agent-session.ts:3226-3227`）与自定义工具 HTML 预渲染。后者分两路：bash/read/write/edit/ls 五个内置工具由模板直接渲染，其余走工具定义的 TUI 渲染器经 ANSI→HTML 转换（`export-html/index.ts:183-230`、`tool-renderer.ts`、`ansi-to-html.ts`）。导出前无预览步骤；查看器内的过滤/展开属于交付物交互而非导出前编辑。

## 6. 图片、HTML、PDF 与富内容生成

- HTML 生成是“模板字符串替换”路线，非 DOM 重排或截图；无图片/PDF 生成能力（本次未找到）。
- 富内容保真（`template.js` 渲染器）：管线配置上，Markdown 用内联 marked、禁 HTML tokenizer（HTML 当纯文本，对齐 TUI）、GFM+breaks、hljs 高亮（指定语言失败回退 auto-detect，再失败转义）、链接与图片 scheme 白名单（https、mailto、tel、ftp）。渲染对象上，思考块、工具卡（bash/read/write/edit/ls 专用版式 + 其余 JSON fallback + 自定义工具预渲染 HTML）、compaction/分支摘要折叠卡、skill 调用折叠卡、图片网格均有对应渲染。KaTeX/Mermaid 本次未在导出端发现（未内联 MathJax/Mermaid 库）。
- 工具结果长输出折叠（前 N 行预览 + “…(N more lines)”展开），`formatExpandableOutput`（`template.js:848-902`）。

## 7. 生成历史、版本与持久化

本次未找到版本历史概念：导出每次覆写或新写目标文件；Radius 与 Gist 分享每次都创建新的外部对象，已创建链接不在本地持久化。客户端没有比较、恢复或更新旧分享对象的入口。

## 8. 分享载体、访问控制与撤销

`/share` 先由 `shareSession` 选择传输路径（`modes/interactive/session-share.ts:56-103`）：默认按 Radius → gist 回退，也可用 destination 选项强制走其中一条：

- Radius 路径：provider 与凭据都可用时，导出把当前分支写成 JSONL，并追加一条 `pi.share` custom entry，把本轮实际的 system prompt 与激活工具的参数 schema 一并存入，再上传为组织可见的 artifact；上传失败按错误返回，不再改走 Gist。
- Gist 回退的前提是 Radius 不可用或没有凭据，此时才检查 `gh auth status`，`gh` 未安装或未登录会提示用户先修复。
- 回退路径把 `session.html` 写到临时目录，再由子进程执行 `gh gist create --public=false` 创建 secret Gist，单文件、无 description（`session-share.ts:182`）。
- 创建成功后从 `gh` 输出的 URL 尾部截取 gistId，拼成查看链接，默认 `https://pi.dev/session/#<gistId>`，可用环境变量 `PI_SHARE_VIEWER_URL` 覆盖（`config.ts:502-508`，说明见 `docs/environment-variables.md:88`）。
- 上传的内容是一份自包含 HTML：头部、全部条目、leafId、system prompt、工具定义与预渲染工具 HTML 都以 base64 JSON 嵌在页面里；消息、标题与元数据同样只以会话数据的形式存在，Gist 本身没有标题字段。
- 访问语义：secret Gist 沿用 GitHub“有链接即可访问”的平台语义；同仓库 `.pi/extensions/import-repro.ts:263-281` 用不带认证头的匿名 `GET https://api.github.com/gists/{id}` 拉取文件，创作者侧的消费路径不依赖登录态。客户端没有撤销、更新或删除路径，Gist 生命周期交回 GitHub，直到手动删除；分享 URL 的不可猜测程度（32 位十六进制 ID）与可枚举性由 GitHub 决定，未运行验证。
- `pi.dev/session` 查看器本体不在本仓库。模板预留了 iframe srcdoc 注入钩子，即 pi-share-base-url 与 pi-url-params 两个 meta 标签（`template.js:23-29, 1096-1118`），据此推断查看器以 srcdoc 方式嵌入 Gist 内容，并支持 `?leafId=&targetId=` 深链与每条消息的“复制链接”按钮（`template.js:1165-1172`），实际行为未验证。
- 同仓库 CI 复用同一语义：`issue-analysis.yml:539-569` 用 PI_GIST_TOKEN 调用 GitHub API，创建包含 session.html 与 session.jsonl 的 secret Gist，再把 gist URL 与分享 URL 评论到 issue（GitHub Actions bot）；`.pi/extensions/import-repro.ts:236-261` 再从 issue 评论中提取 gistId。

## 9. 隐私、安全与内容治理

- 导出/分享**无隐私提示、无脱敏**：HTML/JSONL 原样携带 thinking、bash 命令与输出、文件路径、read 出的文件内容、图片与自定义消息；HTML 和 Radius 载荷还可包含 system prompt 与工具定义。`/share` 在上传 Radius artifact 或创建 Gist 前都没有内容确认或警告。API 密钥本身不进入会话文件，但工具输出中的秘密会原样进入交付物。
- 分享方向（HTML）做了输入侧硬化：marked 禁用原生 HTML 渲染（HTML 按纯文本输出）、链接/图片 scheme 白名单并剥离 C0 控制字符、href/id/mimeType/data 全部做 HTML 转义（`template.js:607-626,1557-1637`）。对应的静态断言测试为 `test/export-html-xss.test.ts`、`export-html-skill-block.test.ts`、`export-html-whitespace.test.ts`。自定义工具预渲染 HTML 直接注入 innerHTML，其安全性依赖工具渲染器自身输出（静态推断）。
- 分享方向（Gist/查看器）的访问控制完全依赖 GitHub secret Gist 与查看器服务端；pi 客户端无任何服务端治理参与。

## 10. 性能、失败恢复与测试

- 失败处理分两条命令：`/export` 抛出的异常统一转成错误提示；`/share` 在创建过程中显示可取消的加载指示，取消时终止子进程、恢复编辑器并删除临时文件，`gh` 返回非零退出码或 gistId 解析失败都会显式报错，临时文件在成功与失败路径上都会尝试清理（`interactive-mode.ts:5884-5953`）。
- HTML 生成走 `Buffer.from(...).toString("base64")` 加同步 writeFileSync 的一次性序列化，大会话没有分块或体积上限处理；静态推断下，导出产物随条目数线性增长。
- 测试覆盖集中在模板文本的静态断言：`test/export-html-*.test.ts` 检查转义、白名单、skill 块与空白，`test/suite/regressions/5596-missing-theme-export.test.ts` 覆盖 `exportToHtml` 的 theme 路径。`/share` 的 gh 子进程没有 mock 测试，HTML 离线打开与 Gist 可访问性也都没有运行证据。

## 11. 设计取舍与已确认边界

- **同一会话、两种口径**：JSONL 导出线性化当前分支（可往返），HTML 导出嵌入完整树（保留分支与隐藏内容但不可直接导回）。文档与代码对“导出=分支”的表述仅针对 JSONL（`agent-session.ts:3243-3248` 注释）。
- **HTML 交付物即分享稿**：自包含、零外部依赖，牺牲体积换取可离线查看与 Gist 单文件托管；代价是无导出前编辑/预览、无图片/PDF 形态。
- **分享止于创建链接**：Radius 路径把访问控制与保留期交给 Radius artifact 服务，回退路径交给 GitHub 与 pi.dev 查看器；客户端的职责止于发起创建与取回链接，后续的保留与撤销由对应服务承担。
- **研究发布走仓库外闭环**：本仓库止步于“可移植会话格式 + README 引导”，HF 发布（`badlogic/pi-share-hf`）与数据集（`badlogicgames/pi-mono`）作为外部伴生工具存在；会话 JSONL v3 与 `docs/session-format.md` 共同构成该闭环的数据契约。
- 隐私无护栏是有意为之还是疏漏，本次无从判断：`/share` 上传的是含完整工具输出的 HTML，而 README 鼓励公开分享 OSS 会话，两者之间没有内容检查环节。

## 12. 未验证事项

- HTML 在浏览器里双击本地文件打开的行为，包括 base64 数据解析、剪贴板与深链功能、图片能否显示，都需要实际运行验证。
- secret Gist 的匿名可访问性、URL 可枚举性、保留期与删除路径——GitHub 平台行为，需实际运行 `/share` 验证。
- `pi.dev/session` 查看器如何取 Gist、注入 srcdoc meta、解析 `#gistId`——服务端在仓库外，未验证。
- HTML 查看器“下载 JSONL”产物以 `type:'header'` 开头，被 `/import` 拒绝时的具体表现属于静态推断，尚未运行验证。
- `badlogic/pi-share-hf` 的数据来源（是否直接消费本仓库 JSONL）、隐私提示、HF 仓库与权限默认值——仓库外，未调查。
- 超大会话导出的 HTML 体积与内存表现、`gh gist create` 在大文件上的行为——未运行。
- 自定义工具预渲染 HTML 注入的 XSS 实际风险——依赖第三方工具渲染器输出，未评估。

## 13. 分享载荷与交付路径

`/share` 先导出当前分支的 JSONL，再在已配置且具备有效凭据时上传至 Radius 的组织可见 artifact；导出的附加 custom entry 包含本轮实际 system prompt 和激活工具的名称、描述与参数 schema。上传成功后只显示 artifact 的 canonical URL。没有 Radius provider 或凭据时，才退回以 `gh gist create --public=false` 创建私密 gist 的旧路径（`packages/coding-agent/src/modes/interactive/session-share.ts:24-151`）。因此分享内容的上下文完整度提高，但 Radius artifact 与 gist 分别受其外部平台的可见性和留存规则约束。

## 14. 关键源码索引

- `packages/coding-agent/src/modes/interactive/interactive-mode.ts`（`/export`、`/import`、`/share`、`/copy` 处理：5773-5972；分发：2895-2914）
- `packages/coding-agent/src/core/agent-session.ts`（`exportToHtml` 3225-3241、`exportToJsonl` 分支线性化 3249-3280）
- `packages/coding-agent/src/core/export-html/index.ts`（模板装配 143-175、`exportSessionToHtml` 236-282、`exportFromFile` 288-316、自定义工具预渲染 183-230）
- `packages/coding-agent/src/core/export-html/template.js`（分支/树渲染、过滤、下载 JSONL、深链、marked 安全配置）
- `packages/coding-agent/src/core/export-html/template.html` / `template.css`（全内联结构）
- `packages/coding-agent/src/core/session-manager.ts`（`getBranch` 1260、`getEntries` 1301、`loadEntriesFromFile` 514、`CURRENT_SESSION_VERSION=3`）
- `packages/coding-agent/src/config.ts`（`getShareViewerUrl` 502-508）
- `packages/coding-agent/src/cli/args.ts` + `src/main.ts`（`--export` 149、626-638）
- `packages/coding-agent/src/modes/rpc/rpc-mode.ts`（`export_html` 596-598）
- `packages/coding-agent/src/core/agent-session-runtime.ts`（`importFromJsonl` 361-396）
- `.pi/extensions/import-repro.ts`（匿名拉 Gist、HTML→JSONL 回解、往返消费）
- `.github/workflows/issue-analysis.yml`（CI 导出与 secret Gist 发布 500-569）
- `README.md` / `packages/coding-agent/README.md`（OSS 会话分享引导与 pi-share-hf 交接 90-104 / 21-35）
- `packages/coding-agent/docs/session-format.md`（JSONL v3 数据契约）
- `scripts/session-transcripts.ts`（仓库内文本抽取/分析工具，非分享交付）
