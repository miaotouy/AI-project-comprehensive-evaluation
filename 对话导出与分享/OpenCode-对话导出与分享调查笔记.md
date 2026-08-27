# OpenCode 对话导出与分享调查笔记

> 调查对象：`https://github.com/anomalyco/opencode`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`c2eacd72afc4a4984564c393e15ab30011057269`（分支：`dev`）
>
> 调查方式：静态源码调查；读取 CLI export/import/pr/run 命令、share 客户端服务（share-next.ts/session.ts）、httpapi session 组、SessionV1 schema、core 持久化（session_share 表、share_url 列、projector）、TUI 与 Web 会话命令、GitHub Actions 分享交接及对应测试；未运行应用
>
> 调查范围：会话 JSON 导出/导入、share_url 生成与同步/撤销、export --sanitize 脱敏、PR 续作；不覆盖云端分享服务端实现（在仓库外）、聊天现场渲染、整库备份
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 在"对话导出与分享"类目提供两条主链：本地 JSON 档案（`opencode export` / `opencode import`，Web 端等价下载）与远端实时分享（TUI /share 命令、Web 面板、`run --share`、GitHub Actions 自动分享）。两者采用同一内容口径：持久化的结构化原文（会话元数据与全部 part 类型，schema 细节见第 2 节），不经过渲染稿投影。

能力分型上属于 `E1 数据交换`（JSON 导出 + 可往返导入）加 `E4 链接分享`；本次未找到 Markdown/HTML/PDF/PNG 交付物、分享稿编辑器、选区导出或数据集发布（`E2/E3/E5` 不适用）。

- **脱敏**：`--sanitize` 只存在于 CLI 导出，按 part 类型逐字段替换为 `[redacted:kind:id]`，但 assistant 错误体（APIError.responseBody）、retry part、tool 错误字段等不在覆盖表内；Web 导出与分享链路不做任何脱敏。
- **实时分享而非快照**：本地监听会话、消息、part、diff 四类事件，按会话去抖 1000ms 后批量 POST 到远端 `sync` 端点；服务端对象在仓库外（默认 `https://opncd.ai`，登录后经 enterprise/console 的 `/api/shares` 并带 Bearer 与组织 ID）。本地只持久化 `session_share` 表与会话的 `share_url` 列。
- **PR 续作**：`opencode pr <number>` 通过解析 PR body 里的分享链接 → 子进程 `opencode import` → 解析回传的会话 ID → `opencode -s <id>` 继续；导入保留原会话/消息/part ID，会话身份得以延续。

## 系统边界与完整主链

```text
本地导出：Session.Service.get + messages（全量分页）
  -> 可选 sanitize（仅 CLI --sanitize）
  -> stdout JSON {info, messages:[{info, parts}]}
  -> opencode import <file> 直接写库重建（ID 保留）

远端分享：session.share HTTP -> SessionShare.share -> ShareNext.create POST 远端
  -> 远端返回 {id, url, secret} -> 本地 session_share 表 + session.share_url
  -> 初始 full() 全量推送 -> 事件 watcher 增量 sync（去抖批量）
  -> unshare DELETE 远端 + 删本地行
  -> 消费者：opencode import <share-url>（GET /api/share/:id/data 扁平数组）

PR 续作：opencode pr <number> -> gh pr checkout -> 解析 PR body 分享链接
  -> opencode import <url> -> 提取 Imported session: <id> -> opencode -s <id>
```

分享服务端（create/sync/remove/data 端点的实现、公开页渲染、访问控制）不在本仓库：本地只有 `share-next.ts` 这个 HTTP 客户端和 `SessionShare` 门面。`packages/console` 中未找到对应端点实现。

## 1. 入口、用户目标与导出源

| 入口 | 位置 | 目标 |
|---|---|---|
| `opencode export [sessionID]` | `packages/opencode/src/cli/cmd/export.ts:222` | 个人存档/迁移；无 ID 时交互列表选择（`prompts.autocomplete`，按 updated 排序，`:257-270`） |
| `opencode import <file|url>` | `cli/cmd/import.ts:94` | 恢复会话到当前项目 |
| `opencode pr <number>` | `cli/cmd/pr.ts:8` | 检出 PR 分支并从 PR body 中的分享链接续作 |
| `opencode run --share` / `--auto-share` | `cli/cmd/run.ts:161,535-548` | headless 跑完后打印分享 URL |
| TUI `/share` `/unshare` 与命令面板 | `packages/tui/src/routes/session/index.tsx:466-610` | 分享/复制/撤销 |
| Web 命令面板 `session.export/share/unshare` | `packages/app/src/pages/session/use-session-commands.tsx:422-500` | 下载 JSON / 分享 / 撤销 |

导出源是**整会话**：消息服务按会话分页取全量（每页 50，`session.ts:830-850`），无单条消息、范围、选区或分支子集选择；顺序按消息时间升序。fork 是独立会话（`SessionInfo.parentID` 保留在导出数据中，但父会话内容不导出）。Web 端导出与 CLI 形状完全一致（`packages/app/src/utils/session-export.ts:19-39`），文件名由 title/slug/id 清洗生成（`:41-48`）。

## 2. 范围选择、内容口径与字段过滤

内容口径是**持久化原始数据**，不采用可见渲染或请求 payload：导出对象只含会话元数据与消息数组（`export.ts:287`），消息按 `SessionV1.WithParts`（`schema/src/v1/session.ts:493-500`）序列化全部 11 种 part 类型。system 提示在 user 消息的 `info.system` 字段原样导出；reasoning part 原样导出；工具调用以结构化 ToolPart 导出（携带 callID、工具名、状态与 input/output 等字段）；API 调用记录不形成独立导出物，但 assistant 消息的 error（含响应体/响应头）与重试 part 的错误字段会随结构化数据导出。

未开启脱敏开关前，导出无任何过滤或转换。

## 3. 脱敏规则（--sanitize）

脱敏规则（`export.ts:163-220`）：非空字符串整体替换为 `[redacted:kind:id]` 模板（空字符串原样保留），非空对象替换为带 kind 与 id 的占位对象。按字段生效：

- **会话层**：title、directory、summary.diffs（file+patch）、revert.snapshot/diff。
- **user 消息**：system、summary.title/body/diffs。
- **assistant 消息**：path.cwd、path.root。
- **part 层**：按 part 类型逐项覆盖：
  - text / reasoning：正文与 metadata
  - file：url、filename、source 的 path/name/text/uri/clientName，含 attachments 里的 filepart
  - subtask：prompt、description、command
  - tool：input、raw、title、output、metadata、attachments
  - patch：hash 与 files；snapshot；step-start/finish 的 snapshot
  - agent：source.value

**脱敏未覆盖字段**（源码确认，`export.ts:69-159` 各分支可见）：

- assistant 消息的 `error`（含响应体/响应头/metadata）与 `structured`；
- retry part 整体走 default 分支不处理；
- tool 处于 error 状态时的 error 字段；
- 会话层：`info.share.url`、permission 规则集、metadata、slug、projectID、tokens/cost 等。

分享链路（share-next 的 full/sync）与 Web 导出均不调用 sanitize。

## 4. 附件、资源与离线封装

FilePart 是引用式：`url` 字符串 + 可选 `source`（类型为 file/symbol/resource，含已抽取的文本 span）。导出/分享均不内联、不打包文件内容本身（除非内容已在 source 文本中）；工具 attachments 同样只带 FilePart。因此交付物可离线打开的只是 JSON 文本，消息图片等外部资源仍是指向原存储的引用。脱敏模式下 url/文件名/source 文本会被打码。无跨域代理或内容下载逻辑。

## 5. 格式、schema 与往返能力

唯一格式是无版本头的 JSON，结构固定为 `{info, messages:[{info, parts}]}`；schema 即 `Session.Info` 与 SessionV1 的消息/part 结构（Effect Schema，`schema/src/v1/session.ts`）。导出为带缩进的标准 JSON（`export.ts:289`）。`SessionInfo.version` 是应用版本字段而非导出格式版本。

往返：导入先用 schema 校验，随后直接写库——session 行按冲突更新（只覆盖 project_id、directory、path），消息与 part 行遇重复则跳过（`import.ts:179-226`）。导入保留原会话/消息/part ID（会话身份延续的基础），但 projectID、directory、path 一律覆盖为当前实例（`:179-184`），share 的 URL 字段经 `toRow`（`session/session.ts:120-159`）写回 share_url。

分支关系经 parentID 保留，但父会话不会随之导入。导入走 URL 时，URL 解析入口只接受新格式 `/share/<slug>`（`import.ts:28-31`；测试确认 `/s/` 为 legacy 格式，`test/cli/import.test.ts:53`）；远端扁平数组再按 messageID 重新分组为嵌套结构（`import.ts:60-90`）。

## 6. 分享稿编辑、编排与预览

不适用：本次未找到分享稿编辑器、选区/主题/水印编排、实时预览或生成版本工作台。分享即"当前全量数据"的一次性建立 + 事件驱动持续同步，Web 查看端在仓库外。

## 7. 分享载体、访问控制与撤销

**载体**：远端分享服务（仓库外）。`ShareNext.request`（`share/share-next.ts:206-222`）按登录态决定目标：无登录账号与组织时，用默认服务地址 `https://opncd.ai` 且不带认证头；有 active 账号与组织时，用账号所在服务并在请求头带 Bearer 凭据与组织 ID。两个分支分别走 `/api/share` 与 `/api/shares` 路径。create 请求只携带会话 ID，响应返回 id、url、secret 三元组（`:310-336`），URL 由服务端下发（测试样例为 `https://…/share/abc`，`test/share/share-next.test.ts:146-162`）。

**同步语义**：分享对象会实时更新。create 后先做一次全量推送（会话元数据、全部消息与 part、session_diff、模型信息，`:274-299`），随后由四个 watcher 增量同步，事件映射如下：

- session.updated → session
- message.updated → message（user 消息附 model）
- message.part.updated → part
- session.diff → session_diff
- session.deleted → 自动 remove（`:179-200`）

增量按会话聚合进队列，1000ms 去抖后批量 POST 到 `/api/share/:id/sync`（请求体含 secret），失败仅记 warning 日志（`:247-272`；去抖合并行为有测试 `share-next.test.ts:227-323`）。

**访问控制**：本地侧更新/删除以 secret 为凭据（sync/remove 都带 secret）；data 端点匿名可读——导入仅在分享 URL 与账号同源时才附加认证头（`import.ts:33-39`；测试 `test/cli/import.test.ts:59-68`）。URL 可猜测性、登录要求与内容保留期在服务端，无法从本仓库确认。

**撤销**：unshare 调用先 DELETE 远端 `/api/share/:id`（带 secret），再删本地 session_share 行并清空会话上的 share 字段（`share-next.ts:338-359`、`share/session.ts:34-37`）。会话删除事件也会自动 remove。配置层面有两种禁用方式：`config share: "disabled"` 时分享门面直接抛错（`share/session.ts:28`）。环境变量 `OPENCODE_DISABLE_SHARE=true/1` 时整个分享客户端短路，create 返回空对象（`share-next.ts:23,311`）。

**共享 URL 的另一套约定**：GitHub Actions（`cli/cmd/github.handler.ts:513-518,1349-1358`）分享后使用 `https://opencode.ai/s/<会话 ID 后 8 位>` 拼链接与社交卡片图片，不走服务端下发的 url——与 `/share/<slug>` 新格式并存。

## 8. PR 续作：身份与上下文保留

`opencode pr <number>`（`cli/cmd/pr.ts`）分四步完成续作：

1. `gh pr checkout` 到本地 `pr/<number>` 分支（--force），cross-repo 时加 fork remote 并设 upstream；
2. 用正则 `/https:\/\/opncd\.ai\/s\/([a-zA-Z0-9_-]+)/` 在 PR body 中找分享链接（`:76`）；
3. 子进程执行 `opencode import <url>`（`:83`），从 stdout 匹配 `Imported session: <id>`（`:86`）；
4. 以 `opencode -s <sessionID>` 启动交互续作（`:101-110`）。

会话身份与上下文的保留方式：分享数据是含原始消息/part ID 的完整结构化轨迹；import 按原 ID 重建会话（见第 5 节）；续作用 `-s` 直接挂到导入后同 ID 的会话。无额外映射表。

静态发现的格式不一致（源码确认，行为未运行验证）：`pr.ts` 只匹配 legacy 格式 `opncd.ai/s/<id>`，而 import 端的 URL 解析只接受新格式 `/share/<slug>`（其测试明示 `/s/` 已被弃用，`test/cli/import.test.ts:53`）。GitHub Actions 张贴的 `opencode.ai/s/<id>` 链接两个正则都不匹配；若 PR body 中是新格式链接，`opencode pr` 将跳过续作。

## 9. 分享配置与自动分享

`config.share` 取值 manual/auto/disabled，可选（缺省即 manual 语义）（`core/src/config.ts:47` 与 `v1/config/config.ts:57`）。已废弃的 `autoshare` 在设为 true 时会迁移为 `share:"auto"`（`packages/opencode/src/config/config.ts:575-577`）。

配置为 auto，或运行参数带 `--share`/`--auto-share` 时，新会话创建即自动分享（`share/session.ts:39-46`；run 入口见第 1 节表格）。TUI 首次分享有一次性确认弹窗（`tui/src/routes/session/index.tsx:488-492`）；Web 端无确认弹窗。

## 10. 性能、失败恢复与测试

- sync 失败（HTTP≥400）只记 warning 且该批数据出队，后续事件会重新入队；create 失败经 `httpOk` 转为错误（HTTP 层映射 500，`httpapi/handlers/session.ts:254-271`），本地不落库。
- 测试覆盖：`test/share/share-next.test.ts`（匿名/认证路由选择、create/remove 持久化与远端调用、diff 事件去抖合并）、`test/cli/import.test.ts`（URL 解析、数据重分组、同源鉴权头规则）。**本次未找到** export/sanitize 与 pr 续作的测试。
- 无大会话分页压力测试、无分享服务端契约测试；CLI 交互与真实分享链路未运行验证。

## 11. 设计取舍与已确认边界

- 导出与分享共享同一"全量结构化原文"口径，但脱敏只做在 CLI 导出这一侧，分享与 Web 导出无脱敏开关——面向不同受众时隐私责任不一致。
- 分享采用实时同步：任何继续对话/回滚/压缩都会推送到已公开链接；唯一的关闭手段是 unshare。
- 分享服务完全外置：本仓库只是客户端 + 本地记录；`packages/console` 未找到对应端点，服务端行为（认证、保留期、data 端点、公开页渲染）属外部边界。
- `Session.diff` 在本次快照中返回空数组（`session/session.ts:825-828`），初始全量推送里的 session_diff 恒为空；真实 diff 只能靠后续事件同步。
- 两套分享链接约定并存（服务端 `/share/<slug>` vs GitHub Actions `opencode.ai/s/<id>`），且 `pr.ts` 仍识别已弃用的 `opncd.ai/s/` 格式——属静态推断的演进残留，非运行确认。
- 无图片/PDF/HTML 导出、无选区、无生成历史，均未实现（本次未找到，不做虚构）。

## 12. 未验证事项

- CLI 实际运行：`export` 交互选择、stdout 输出、`import` 完整往返（含重复 ID 冲突与 share_url 恢复）。
- 分享服务端行为：`/share/<slug>` URL 是否可枚举、data 端点真实响应结构、无登录可读性、保留期、删除后旧链接状态；`https://opncd.ai` 与 enterprise 服务的真实可用性。
- 实时同步的端到端行为：watcher 时效、重连后的增量完整性、`session_diff` 因 `Session.diff` stub 导致的初始为空对分享页面的实际影响。
- `opencode pr` 续作全流程（gh 认证、cross-repo 分支、两种 URL 格式的匹配、`-s` 挂载后上下文是否完整）。
- GitHub Actions 分享（social-card、`opencode.ai/s/<id>` 链接可访问性）。
- Web/TUI 分享与撤销的交互运行结果（剪贴板复制、toast、禁用态）。

## 13. 关键源码索引

- `packages/opencode/src/cli/cmd/export.ts`（ExportCommand、sanitize `:163`、`run` `:240`）
- `packages/opencode/src/cli/cmd/import.ts`（parseShareUrl `:28`、shouldAttachShareAuthHeaders `:33`、transformShareData `:60`、ImportCommand `:94`）
- `packages/opencode/src/cli/cmd/pr.ts`（PrCommand、body 链接正则 `:76`、续作 `:101`）
- `packages/opencode/src/share/share-next.ts`（request `:206`、create `:310`、flush `:247`、full `:274`、watchers `:179-200`、remove `:338`、OPENCODE_DISABLE_SHARE `:23`）
- `packages/opencode/src/share/session.ts`（SessionShare.share/unshare/create、config disabled `:28`）
- `packages/opencode/src/session/session.ts`（setShare `:812`、toRow `:120`、messages 分页 `:830-850`、diff stub `:825`）
- `packages/opencode/src/server/routes/instance/httpapi/handlers/session.ts:259-271`、`groups/session.ts:279-302`
- `packages/core/src/share/sql.ts`（session_share 表）、`packages/core/src/session/sql.ts:37` 与 `projector.ts:57`（share_url）
- `packages/schema/src/v1/session.ts`（SessionInfo `:543`、Info/WithParts `:490-500`、11 种 Part）
- `packages/app/src/utils/session-export.ts`、`packages/app/src/pages/session/use-session-commands.tsx:236-259,422-444`
- `packages/tui/src/routes/session/index.tsx:466-610`、`sidebar.tsx:54,80-81`
- `packages/opencode/src/cli/cmd/github.handler.ts:513-518,577,1349-1358`、`cli/cmd/run.ts:161,535-548`
- `packages/opencode/test/share/share-next.test.ts`、`test/cli/import.test.ts`
