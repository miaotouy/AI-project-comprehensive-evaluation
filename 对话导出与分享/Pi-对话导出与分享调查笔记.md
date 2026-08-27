# Pi 对话导出与分享调查笔记

> 调查对象：`https://github.com/earendil-works/pi`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`e86823096c5bad39e1ca282ec24bc5eb9bec745b`（分支：`main`）
>
> 调查方式：静态源码调查；读取 TUI 的 `/export`、`/import`、`/share`、`/copy` 处理链，`export-html` 模板（index/template.html/template.js/template.css/ansi-to-html/tool-renderer），SessionManager 树模型与 JSONL 读写，CLI `--export`、RPC `export_html`，`.pi/extensions/import-repro.ts`，`.github/workflows/issue-analysis.yml`，README 与 docs；未运行应用、浏览器、GitHub CLI 或 Hugging Face 操作
>
> 调查范围：HTML/JSONL 导出的导出源与分支语义、HTML 自包含性、Gist 分享内容与访问语义、HF 数据集发布的仓库边界与提示、各入口与导出源范围；不覆盖会话管理 CRUD、压缩/分支摘要机制本体和 pi.dev/session 查看器服务端实现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 的对话导出与分享围绕“会话即 JSONL 树”这一事实源展开，能力分属 `E1 数据交换`、`E4 链接分享` 和 `E5 发布与研究`（交接侧）：

- **JSONL 导出（`/export x.jsonl`）是把当前分支线性化**：取 `getBranch()` 从叶子到根的路径条目，重排 `parentId` 成线性链写盘，侧枝与完整树不进入该文件；但**HTML 导出嵌入了完整树**（所有 entries + leafId），默认按当前分支渲染，查看器侧栏可浏览并切换任意分支。两种导出口径不同。
- **HTML 是单文件自包含交付物**：CSS、应用 JS、marked.min.js、highlight.min.js 全部内联（`export-html/index.ts:143-175`），会话数据以 base64 JSON 嵌在 `<script id="session-data">` 中，图片内容块以 data: URL 渲染；无外部 CSS/JS/字体依赖，可离线打开（推断，未运行验证）。Markdown 中引用远端图片的 URL 仍保持引用，离线时该图不显示。
- **`/share` 上传的是这份自包含 HTML**：先导出到临时文件，再 `gh gist create --public=false` 创建 secret Gist（单一 `session.html` 文件），拼出 `https://pi.dev/session/#<gistId>`。客户端只创建链接：无更新、撤销、删除、过期路径，也不记录已创建的 Gist。
- **HF 数据集发布位于仓库外**：本仓库只承担“交付物与格式 + 引导”角色。README 指引使用外部伴生工具 `badlogic/pi-share-hf` 把会话发布为 HF 数据集（示例 `badlogicgames/pi-mono`）；数据来源、提示与权限默认值由外部工具负责，本次未找到仓库内任何 HF 上传代码或隐私提示。
- 同仓库的 CI（`issue-analysis.yml`）复用同一导出链路：把分析会话导出为 HTML+JSONL 后经 GitHub API 创建 secret Gist（`public: false`），并把链接和 `/ir` 导入指令评论到 issue 上；`.pi/extensions/import-repro.ts` 则演示了匿名 `GET api.github.com/gists/{id}` 拉回 HTML/JSONL 并转回会话的往返消费闭环。

## 系统边界与完整主链

```text
事实源：SessionManager 的 JSONL 会话文件（header + entries，id/parentId 树，append-only，leafId 指针）
  ├─ /export [路径]                -> .jsonl 分支线性化（重排 parentId）| .html 完整树 + leafId
  ├─ /export [路径.html]（TUI）     -> exportSessionToHtml（含 systemPrompt/tools/自定义工具 HTML）
  ├─ CLI pi --export in.jsonl [out.html] -> exportFromFile（无 AgentState，不含 systemPrompt/tools）
  ├─ RPC export_html               -> 同上 exportToHtml，供远端客户端（如 pi-chat）调用
  ├─ /share                        -> 导出 HTML -> gh gist create --public=false -> pi.dev/session/#<gistId>
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

- `/export [file]`：按后缀分流，带 .jsonl 走 JSONL、否则走 HTML；无参数时默认输出 `pi-session-<会话文件basename>.html`（`export-html/index.ts:274-278`）。JSONL 无参数时生成带时间戳文件名（`agent-session.ts:3250-3253`）。目标为个人存档与人际传播。
- `/import <path.jsonl>`：确认后复制文件到会话目录并切换运行时（`agent-session-runtime.ts:361-396`），目标为跨机恢复与接续。
- `/share`：一键把当前会话发布为 secret Gist 并给出查看链接，目标为分享给他人查看（`interactive-mode.ts:5862-5954`）。
- `/copy`：复制最后一条助手消息文本到剪贴板（`interactive-mode.ts:5956-5972`、`agent-session.ts:3291-3306`）；属于普通复制，不构成选区/格式工作流。
- CLI `--export <in> [out]`：非交互地把任意会话文件转 HTML 后退出（`main.ts:626-638`；`args.ts:149-150, 288, 356-357`）。
- RPC `export_html`：对外部进程/客户端暴露的导出命令（`rpc-types.ts:59`、`rpc-mode.ts:596-598`）。

导出源粒度：只有“整会话”一个粒度。未发现单消息、连续范围、选区或批量会话导出入口；`/fork`/`/clone` 创建新会话属于会话管理，不在导出侧。顺序由树结构决定（见下节）。

## 2. 范围选择、内容口径与字段过滤

**JSONL 导出 = 当前分支线性化**（`agent-session.ts:3249-3280`）：

- 头行：`{type:"session", version:CURRENT_SESSION_VERSION(3), id, timestamp, cwd}`（不带 `parentSession`）。
- 条目：`getBranch()`（`session-manager.ts:1260-1270`，从 leafId 沿 parentId 走到根）取当前分支路径，注释明确“Re-chain parentIds to form a linear sequence”——每条重写父指针为前一条的 id。侧枝、分支摘要节点等路径外条目全部丢弃；导入后是线性会话。
- 路径上所有条目类型都保留（message、compaction、model_change、thinking_level_change、label、custom_message、branch_summary 等），不做字段裁剪。

**HTML 导出 = 完整树嵌入 + 分支视图**：

- `sessionData` 携带头部、全部条目（含侧枝与隐藏消息）与 `leafId`，TUI 路径还附带 system prompt、工具定义与预渲染工具 HTML（`export-html/index.ts:263-270`）。
- 模板 JS 用 `getPath(leafId)` 渲染消息视图（当前分支），用 `buildTree()` 渲染侧栏完整树；点击树节点跳转到该节点下最新叶子（`template.js:73-176, 133-145, 1495-1551`）。
- 内容口径是“持久化原始数据”（含 thinking、工具调用/结果、bash 命令与输出、文件路径、图片 base64），未转换为请求 Payload，也未生成脱敏副本。
- 树/消息的显隐由查看器端过滤控制：默认模式隐藏设置类条目（label、custom、model_change、thinking_level_change），另有 no-tools / user-only / labeled-only / all 过滤与搜索（`template.js:368-424`，模板按钮在 `template.html:20-27`）。这些是查看时过滤，导出文件本身始终含全部条目。
- 隐藏消息：工具结果条目内联进对应助手工具调用块，消息视图不单独渲染（`template.js:904-1063,1287`）；thinking 块默认展开、可折叠（`template.js:1249-1254,1792-1800`）；自定义消息仅 display 为 true 的渲染（`template.js:1309-1314`）。

## 3. 附件、资源与离线封装

- 生成 HTML 时把模板 CSS、模板 JS 与 marked、highlight 两个 vendor 库全部读入并替换进 `template.html` 占位符（`export-html/index.ts:143-175`）；模板文件本身无任何外部脚本、样式、导入或 URL 引用（`template.html` 全文），字体用系统字体栈（`template.css:19`）。
- 会话图片内容块（`ImageContent` 的 base64 data）以 `data:<mimeType>;base64,<data>` 内联（`template.js:924, 1208, 1230`），离线可见。
- Markdown 正文中的图片 URL 走 `sanitizeMarkdownUrl` 后原样输出 `<img src>`（`template.js:616-626, 1599-1610`），保持远端引用；离线打开时这类图片需网络。
- 结论：HTML 交付物基本单文件自包含，可复制为单个文件离线打开（静态推断，未运行验证）；“本地文件双击打开”下深链与剪贴板 API 的部分行为依赖浏览器能力。

## 4. 格式、schema 与往返能力

- 格式只有 JSONL（v3，见 `docs/session-format.md` 的完整字段文档）与 HTML（v3 数据嵌 base64 JSON）两种；未发现 Markdown/PDF/PNG 导出、剪贴板图片导出或打印链路（搜索 `pdf|toPng|print` 只命中与导出无关的终端图片转换/CLI print 模式）。
- JSONL 无独立导出 schema 版本：头行带 `version: 3`，条目即持久化格式原样。往返：导入走 `loadEntriesFromFile`（`session-manager.ts:514-556`），要求首行 `type:"session"` 且有 id，容忍坏行跳过；随后打开会话并把最后一条设为 leaf。因此 `/export x.jsonl` 的产物可直接导回，但分支关系已被线性化，无法还原侧枝；未知字段原样保留。
- HTML 查看器内置“下载 JSONL”按钮（`template.js:1069-1090`）重建头部 + 全部条目（完整树、不重排 parentId）。按导入端校验要求，该文件首行是 `type:'header'` 而非 `type:'session'`，会被判为“not a valid pi session”（静态推断，未运行验证）。`.pi/extensions/import-repro.ts:96-118` 从 HTML 反向提取时写回的是 `type:'session'` 头、可导入。两处 JSONL 重建口径不一致。
- `docs/session-format.md` 与代码一致地声明 v3 = 树结构（`session-manager.ts:30`）。

## 5. 分享稿编辑、编排与预览

本次未找到独立于聊天现场的“分享稿编辑器”。HTML 导出即交付物：无选区编辑、内容开关（导出前）、主题之外无布局/品牌配置，唯一的导出期变量是 `themeName`（`agent-session.ts:3226-3227`）与自定义工具 HTML 预渲染。后者分两路：bash/read/write/edit/ls 五个内置工具由模板直接渲染，其余走工具定义的 TUI 渲染器经 ANSI→HTML 转换（`export-html/index.ts:183-230`、`tool-renderer.ts`、`ansi-to-html.ts`）。导出前无预览步骤；查看器内的过滤/展开属于交付物交互而非导出前编辑。

## 6. 图片、HTML、PDF 与富内容生成

- HTML 生成是“模板字符串替换”路线，非 DOM 重排或截图；无图片/PDF 生成能力（本次未找到）。
- 富内容保真（`template.js` 渲染器）：管线配置上，Markdown 用内联 marked、禁 HTML tokenizer（HTML 当纯文本，对齐 TUI）、GFM+breaks、hljs 高亮（指定语言失败回退 auto-detect，再失败转义）、链接与图片 scheme 白名单（https、mailto、tel、ftp）。渲染对象上，思考块、工具卡（bash/read/write/edit/ls 专用版式 + 其余 JSON fallback + 自定义工具预渲染 HTML）、compaction/分支摘要折叠卡、skill 调用折叠卡、图片网格均有对应渲染。KaTeX/Mermaid 本次未在导出端发现（未内联 MathJax/Mermaid 库）。
- 工具结果长输出折叠（前 N 行预览 + “…(N more lines)”展开），`formatExpandableOutput`（`template.js:848-902`）。

## 7. 生成历史、版本与持久化

本次未找到版本历史概念：导出每次覆写/新写目标文件，无“重新生成覆盖或追加”的显式记录；分享每次创建新 Gist，已创建链接不在本地持久化（全仓未发现分享记录存储；`/share` 只 showStatus 一次）。

## 8. 分享载体、访问控制与撤销

`/share`（`interactive-mode.ts:5862-5954`）：

- 前置检查：`gh auth status` 非零则提示先 `gh auth login`；未安装 gh 则提示安装（`5864-5873`）。
- 导出 `session.html` 到临时目录，随后以子进程执行 `gh gist create --public=false`（`5914`）——secret Gist、单文件、无 description。
- 从 `gh` 输出 URL 尾部截取 gistId，拼出查看链接：默认 `https://pi.dev/session/#<gistId>`，可用环境变量 `PI_SHARE_VIEWER_URL` 覆盖（`config.ts:502-508`）。文档见 `docs/environment-variables.md:88`。
- 上传的内容是自包含 HTML（其中嵌有头部、全部条目、leafId 与 system prompt、工具定义、预渲染工具 HTML 的 base64 JSON）。“消息/标题/元数据”均以会话数据形式存在于 HTML 内，Gist 本身无标题字段。
- 访问语义：secret Gist 属于“有链接即可访问”的 GitHub 平台语义；同仓库 `import-repro.ts:263-281` 用匿名 `GET https://api.github.com/gists/{id}`（无认证头）拉取 Gist 文件，说明创作者侧的消费路径不依赖登录态。撤销/更新/删除路径在客户端本次未找到；Gist 生命周期完全交给 GitHub（手动删除为止），分享 URL 无法猜测性（32 位十六进制 ID）与可枚举性由 GitHub 决定，未运行验证。
- `pi.dev/session` 查看器本体不在本仓库。模板预留了 iframe srcdoc 注入钩子（pi-share-base-url、pi-url-params 两个 meta 标签，`template.js:23-29,1096-1118`），推断查看器以 srcdoc 方式嵌入 Gist 内容，并支持 `?leafId=&targetId=` 深链与每条消息的“复制链接”按钮（`template.js:1165-1172`）——查看器实际行为未验证。
- 同仓库 CI 复用同一语义：`issue-analysis.yml:539-569` 用 `PI_GIST_TOKEN` 调用 GitHub API 创建含 session.html 与 session.jsonl 双文件的 secret Gist，随后把 gist URL 与分享 URL 评论到 issue（GitHub Actions bot），`import-repro.ts:236-261` 再从 issue 评论中提取 gistId。

## 9. 隐私、安全与内容治理

- 导出/分享**无隐私提示、无脱敏**：HTML/JSONL 原样携带 system prompt、工具定义、thinking 全文、bash 命令与输出、文件路径、read 出的文件内容、图片与自定义消息；`/share` 在创建 Gist 前没有任何内容确认或警告。API 密钥本身不进入会话文件（auth 存于 `~/.pi/agent/auth.json`），但 bash 输出等可能包含秘密的内容会原样进入交付物。
- 分享方向（HTML）做了输入侧硬化：marked 禁用原生 HTML 渲染（HTML 按纯文本输出）、链接/图片 scheme 白名单并剥离 C0 控制字符、href/id/mimeType/data 全部做 HTML 转义（`template.js:607-626,1557-1637`）。对应的静态断言测试为 `test/export-html-xss.test.ts`、`export-html-skill-block.test.ts`、`export-html-whitespace.test.ts`。自定义工具预渲染 HTML 直接注入 innerHTML，其安全性依赖工具渲染器自身输出（静态推断）。
- 分享方向（Gist/查看器）的访问控制完全依赖 GitHub secret Gist 与查看器服务端；pi 客户端无任何服务端治理参与。

## 10. 性能、失败恢复与测试

- 失败处理：`/export` 异常统一弹错误提示；`/share` 有可取消的加载指示（取消时终止子进程、恢复编辑器、删除临时文件），`gh` 非零退出码、gistId 解析失败均显式报错（`interactive-mode.ts:5884-5953`）；临时文件在成功/失败路径都尝试清理。
- HTML 生成用 `Buffer.from(...).toString("base64")` + 同步 `writeFileSync`，大会话的序列化与体积未发现分块或上限处理（静态推断：超大会话导出时 HTML 体积随条目数线性增长）。
- 测试覆盖：`test/export-html-*.test.ts` 是对模板 JS 文本的静态断言（转义/白名单/skill 块/空白），`test/suite/regressions/5596-missing-theme-export.test.ts` 覆盖 `exportToHtml` 的 theme 路径。未发现 `/share` 的 gh 子进程 mock 测试；HTML 离线打开、Gist 可访问性均无运行证据。

## 11. 设计取舍与已确认边界

- **同一会话、两种口径**：JSONL 导出线性化当前分支（可往返、结构干净），HTML 导出嵌入完整树（保留分支与隐藏内容但不可直接导回）。文档与代码对“导出=分支”的表述仅针对 JSONL（`agent-session.ts:3243-3248` 注释）。
- **HTML 交付物即分享稿**：自包含、零外部依赖，牺牲体积换取可离线查看与 Gist 单文件托管；代价是无导出前编辑/预览、无图片/PDF 形态。
- **分享治理刻意轻量**：/share 只负责“创建链接”，把查看、访问控制、保留期全部交给 GitHub + pi.dev 查看器；客户端不记录、不更新、不撤销。
- **研究发布走仓库外闭环**：本仓库止步于“可移植会话格式 + README 引导”，HF 发布（`badlogic/pi-share-hf`）与数据集（`badlogicgames/pi-mono`）作为外部伴生工具存在；会话 JSONL v3 与 `docs/session-format.md` 共同构成该闭环的数据契约。
- 隐私无护栏是有意为之还是疏漏，本次无从判断：`/share` 上传的是含完整工具输出的 HTML，而 README 鼓励公开分享 OSS 会话，两者之间没有内容检查环节。

## 12. 未验证事项

- HTML 离线打开行为（双击本地文件时 base64 解析、剪贴板/深链、图片显示）——需浏览器运行验证。
- secret Gist 的匿名可访问性、URL 可枚举性、保留期与删除路径——GitHub 平台行为，需实际运行 `/share` 验证。
- `pi.dev/session` 查看器如何取 Gist、注入 srcdoc meta、解析 `#gistId`——服务端在仓库外，未验证。
- HTML 查看器“下载 JSONL”产物（`type:'header'` 头）被 `/import` 拒绝的具体表现——静态推断，未运行。
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
